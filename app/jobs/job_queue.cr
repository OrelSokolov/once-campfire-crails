require "db"
require "json"
require "http/client"
require "random/secure"
require "sqlite3"
require "uuid"

# Leased-SQLite job queue ported from src/jobs.js (once-campfire-express):
# separate DB, random 120s leases, exponential backoff retries, dead after
# 5 attempts, synchronous batch writes before the response, JOB_CONCURRENCY
# worker fibers (default 3).
module Campfire
  class JobQueue
    class Job
      attr_reader id : Int64
      attr_reader payload : String
      attr_reader attempts : Int32
      attr_reader lease_token : String

      def initialize(@id, @payload, @attempts, @lease_token)
      end
    end

    SCHEMA = <<-SQL
      CREATE TABLE IF NOT EXISTS jobs(
        id INTEGER PRIMARY KEY,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        available_at REAL NOT NULL,
        lease_until REAL,
        lease_token TEXT,
        status TEXT NOT NULL DEFAULT 'ready',
        last_error TEXT
      )
    SQL

    @@db : DB::Database?

    # Writers are serialized cross-process via flock in WriteQueue; retry_on_lock
    # is a safety net for external writers (CLI diagnostics and the like).
    def self.db : DB::Database
      @@db ||= begin
        path = File.expand_path(ENV["CAMPFIRE_JOBS_DB"]? || "db/jobs.sqlite3")
        Dir.mkdir_p(File.dirname(path))
        # Pool of 2: the writer fiber (claim/enqueue/finish via WriteQueue)
        # plus the periodic checkpoint fiber.
        database = DB.open("sqlite3://#{path}?max_pool_size=2&max_idle_pool_size=2")
        database.setup_connection do |conn|
          # busy_timeout is a pure safety net for external writers (CLI);
          # our own writers go through flock in WriteQueue.
          conn.exec("PRAGMA busy_timeout=10000")
          # WAL is required (the DELETE journal hit "attempt to write a
          # readonly database" on hot journals in the fork configuration),
          # but auto-checkpoints never finish under continuous claims — hence
          # wal_autocheckpoint=0 plus PASSIVE checkpoints from checkpoint_fiber.
          conn.exec("PRAGMA journal_mode=WAL")
          conn.exec("PRAGMA wal_autocheckpoint=0")
          conn.exec("PRAGMA synchronous=NORMAL")
        end
        database.exec(SCHEMA)
        database
      end
    end

    # Periodic PASSIVE checkpoint of the jobs WAL: without it continuous
    # claim readers keep checkpoints from ever completing.
    def self.start_checkpoint_fiber(interval : Time::Span = 3.seconds) : Nil
      spawn do
        loop do
          sleep interval
          begin
            db.exec("PRAGMA wal_checkpoint(PASSIVE)")
          rescue e
            STDERR.puts "Campfire jobs checkpoint failed: #{e.message}"
          end
        end
      end
    end

    # jobs: array of {kind, data} pairs where data is a JSON string;
    # BEGIN IMMEDIATE with busy_timeout=0 returns SQLITE_BUSY instantly
    # under fork-worker/fiber contention, waiting happens in retry_on_lock
    # fibers (the worker event loop is not blocked).
    def self.enqueue_batch(jobs : Array(Tuple(String, String)),
                           at : Float64 = Time.utc.to_unix_f) : Nil
      return if jobs.empty?
      retry_on_lock do
        db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            jobs.each do |(kind, data)|
              payload = %({"kind":#{kind.to_json},"data":#{data}})
              conn.exec(
                "INSERT INTO jobs (payload, available_at) VALUES (?, ?)",
                payload, at)
            end
            conn.exec("COMMIT")
          rescue e
            conn.exec("ROLLBACK") rescue nil
            raise e
          end
        end
      end
    end

    # Claim goes through WriteQueue on the queue's single connection: within
    # the process enqueue/claim/finish do not contend for the jobs write lock
    # (see write_queue.cr); cross-process contention is handled by retry_on_lock.
    # A transaction-free SELECT comes first so empty polling never touches
    # the write lock at all.
    def self.claim(now : Float64 = Time.utc.to_unix_f) : Job?
      Campfire::WriteQueue.perform do
        has_row = db.using_connection do |conn|
          conn.query_one?(
            "SELECT 1 FROM jobs WHERE status='ready' AND available_at <= ? " \
            "AND (lease_until IS NULL OR lease_until <= ?) LIMIT 1",
            now, now) { |rs| rs.read(Int32) }
        end
        next nil unless has_row

        retry_on_lock do
          db.using_connection do |conn|
            conn.exec("BEGIN IMMEDIATE")
            begin
              row = conn.query_one?(
                "SELECT id, payload, attempts FROM jobs " \
                "WHERE status='ready' AND available_at <= ? " \
                "AND (lease_until IS NULL OR lease_until <= ?) ORDER BY id LIMIT 1",
                now, now) do |rs|
                {id: rs.read(Int64), payload: rs.read(String), attempts: rs.read(Int32)}
              end
              job = nil
              if row
                token = Random::Secure.hex(16)
                conn.exec(
                  "UPDATE jobs SET attempts = attempts + 1, lease_until = ?, lease_token = ? WHERE id = ?",
                  now + 120, token, row[:id])
                job = Job.new(row[:id], row[:payload], row[:attempts] + 1, token)
              end
              conn.exec("COMMIT")
              job
            rescue e
              conn.exec("ROLLBACK") rescue nil
              raise e
            end
          end
        end
      end
    end

    def self.finish(job : Job, error : String? = nil,
                    now : Float64 = Time.utc.to_unix_f) : Nil
      Campfire::WriteQueue.perform do
        retry_on_lock do
          db.using_connection do |conn|
            if error.nil?
              conn.exec("DELETE FROM jobs WHERE id = ? AND lease_token = ?",
                job.id, job.lease_token)
            else
              backoff = Math.min(300, 2 ** job.attempts)
              conn.exec(
                "UPDATE jobs SET lease_until = NULL, lease_token = NULL, " \
                "available_at = ?, status = ?, last_error = ? " \
                "WHERE id = ? AND lease_token = ?",
                now + backoff,
                job.attempts >= 5 ? "dead" : "ready",
                error[0, 1000],
                job.id, job.lease_token)
            end
          end
        end
      end
    end

    def self.start_worker : Nil
      concurrency = ENV["JOB_CONCURRENCY"]?.try(&.to_i?) || 3
      concurrency.times { spawn { worker_loop } }
      start_checkpoint_fiber
    end

    # After fork (serverX Cluster): inherited sqlite handles must not be
    # used — close and reopen lazily.
    def self.reset! : Nil
      @@db.try(&.close)
      @@db = nil
    end

    # See the comment on enqueue_batch: instant SQLITE_BUSY is cured by
    # retrying with a fresh snapshot; 30 short attempts (the contention
    # window is sub-millisecond); "statements in progress" retries for the
    # same reason (a stuck statement self-heals on a repeated exec).
    private def self.retry_on_lock(attempts : Int32 = 30, &)
      tries = 0
      loop do
        tries += 1
        begin
          return yield
        rescue e : SQLite3::Exception
          msg = e.message.to_s
          if (msg.includes?("database is locked") ||
              msg.includes?("statements in progress")) && tries < attempts
            sleep Random.new.rand(0.001..0.008).seconds
            next
          end
          raise e
        end
      end
      raise Exception.new("unreachable") # excludes Nil from the return type
    end

    def self.worker_loop : Nil
      loop do
        job = begin
          claim
        rescue e
          STDERR.puts "Campfire queue failed: #{e.message}"
          nil
        end
        unless job
          sleep 0.25.seconds
          next
        end
        begin
          payload = JSON.parse(job.payload)
          perform(payload["kind"].to_s, payload["data"])
          finish(job)
        rescue e
          STDERR.puts "Campfire job failed: #{e.message}"
          begin
            finish(job, e.message.to_s)
          rescue e2
            STDERR.puts "Campfire job bookkeeping failed: #{e2.message}"
          end
        end
      end
    end

    # ————— Handlers (perform ported from src/jobs.js) —————

    def self.perform(kind : String, data : JSON::Any) : Nil
      klass = case kind
      when "push"     then Room::PushMessageJob
      when "webhook"  then Bot::WebhookJob
      when "remove_banned_content" then RemoveBannedContentJob
      when "room_destroy"          then Room::DestroyJob
      when "broadcast_unread_room" then Message::BroadcastUnreadRoomJob
      else                 raise "unknown job #{kind}"
      end
      begin
        klass.__run(data)
      rescue e : ActiveJob::DeserializationError
        # discard_on: a vanished record ends the job silently instead of retrying.
        raise e unless klass.discards?(ActiveJob::DeserializationError)
      end
    end

  end
end
