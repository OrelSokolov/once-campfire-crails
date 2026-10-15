require "db"
require "json"
require "http/client"
require "random/secure"
require "sqlite3"
require "uuid"

# Leased-SQLite очередь джобов — порт src/jobs.js (once-campfire-express).
# Отдельная БД (db/jobs.sqlite3): claim по случайному lease-токену на 120 с,
# при ошибке retry с экспоненциальным backoff, после 5 попыток status='dead'.
# Запись батча — синхронно из HTTP-запроса до отправки ответа
# («persisted before response»). Воркер — JOB_CONCURRENCY фибр (default 3).
module Campfire
  class JobQueue
    class Job
      getter id : Int64
      getter payload : String
      getter attempts : Int32
      getter lease_token : String

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

    def self.db : DB::Database
      @@db ||= begin
        path = File.expand_path(ENV["CAMPFIRE_JOBS_DB"]? || "db/jobs.sqlite3")
        Dir.mkdir_p(File.dirname(path))
        database = DB.open("sqlite3://#{path}")
        database.setup_connection do |conn|
          # busy_timeout=0: SQLITE_BUSY возвращается мгновенно, а ожидание
          # идёт фиберами retry_on_lock (sleep в шедулере Crystal, event-loop
          # жив). C-сон busy-хендлера из фиберы джоб-воркера заморозил бы
          # воркер при занятом локе (см. Campfire::WriteQueue).
          conn.exec("PRAGMA busy_timeout=0")
          conn.exec("PRAGMA journal_mode=WAL")
          conn.exec("PRAGMA synchronous=NORMAL")
        end
        database.exec(SCHEMA)
        database
      end
    end

    # jobs: массив пар {kind, data} где data — JSON-строка.
    # BEGIN IMMEDIATE при busy_timeout=0: при конкуренции fork-воркеров
    # и job-фибр за write-lock SQLITE_BUSY возвращается мгновенно, ожидание
    # — фиберами retry_on_lock (event-loop воркера не блокируется).
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

    def self.claim(now : Float64 = Time.utc.to_unix_f) : Job?
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

    def self.finish(job : Job, error : String? = nil,
                    now : Float64 = Time.utc.to_unix_f) : Nil
      if error.nil?
        db.exec("DELETE FROM jobs WHERE id = ? AND lease_token = ?",
          job.id, job.lease_token)
      else
        backoff = Math.min(300, 2 ** job.attempts)
        db.exec(
          "UPDATE jobs SET lease_until = NULL, lease_token = NULL, " \
          "available_at = ?, status = ?, last_error = ? " \
          "WHERE id = ? AND lease_token = ?",
          now + backoff,
          job.attempts >= 5 ? "dead" : "ready",
          error[0, 1000],
          job.id, job.lease_token)
      end
    end

    def self.start_worker : Nil
      concurrency = ENV["JOB_CONCURRENCY"]?.try(&.to_i?) || 3
      concurrency.times { spawn { worker_loop } }
    end

    # После fork (serverX Cluster): унаследованные sqlite-дескрипторы
    # нельзя использовать — закрыть и открыть заново лениво.
    def self.reset! : Nil
      @@db.try(&.close)
      @@db = nil
    end

    # См. комментарий у enqueue_batch: мгновенный SQLITE_BUSY у
    # отложенных транзакций лечится повтором со свежим снапшотом.
    private def self.retry_on_lock(attempts : Int32 = 5, &)
      tries = 0
      loop do
        tries += 1
        begin
          return yield
        rescue e : SQLite3::Exception
          if e.message.to_s.includes?("database is locked") && tries < attempts
            sleep Random.new.rand(0.005..0.05)
            next
          end
          raise e
        end
      end
      raise Exception.new("unreachable") # исключает Nil из типа возврата
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

    # ————— Хендлеры (порт perform из src/jobs.js) —————

    def self.perform(kind : String, data : JSON::Any) : Nil
      case kind
      when "push"     then perform_push
      when "webhook"  then perform_webhook(data)
      else                 raise "unknown job #{kind}"
      end
    end

    # Web Push (VAPID) требует ключей окружения; без них — успешный no-op,
    # как у express (`if (!VAPID_PRIVATE_KEY) return`).
    def self.perform_push : Nil
      return unless ENV["VAPID_PRIVATE_KEY"]? && ENV["VAPID_PUBLIC_KEY"]?
      STDERR.puts "Campfire push delivery not implemented (VAPID keys present)"
    end

    def self.perform_webhook(data : JSON::Any) : Nil
      webhook_id = data["webhook_id"]?.try(&.to_s.to_i64?)
      message_id = data["message_id"]?.try(&.to_s.to_i64?)
      return unless webhook_id && message_id

      conn = ActiveRecord::Base.connection
      hook = conn.query_one?(
        "SELECT w.id, w.url, w.user_id, u.name, u.bot_token, u.status " \
        "FROM webhooks w JOIN users u ON u.id = w.user_id WHERE w.id = ?",
        webhook_id) do |rs|
        {id: rs.read(Int64), url: rs.read(String?), user_id: rs.read(Int64),
         name: rs.read(String?), bot_token: rs.read(String?), status: rs.read(Int32)}
      end
      return unless hook && hook[:status] == 0

      message = conn.query_one?(
        "SELECT m.id, m.room_id, m.creator_id, r.name AS room_name, r.type AS room_type, " \
        "u.name AS creator_name FROM messages m " \
        "JOIN rooms r ON r.id = m.room_id JOIN users u ON u.id = m.creator_id WHERE m.id = ?",
        message_id) do |rs|
        {id: rs.read(Int64), room_id: rs.read(Int64), creator_id: rs.read(Int64),
         room_name: rs.read(String?), room_type: rs.read(String?),
         creator_name: rs.read(String?)}
      end
      return unless message
      return unless conn.query_one?(
        "SELECT 1 FROM memberships WHERE user_id = ? AND room_id = ?",
        hook[:user_id], message[:room_id]) { |rs| rs.read(Int32) }

      body = conn.query_one?(
        "SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?",
        message[:id]) { |rs| rs.read(String) }.to_s

      payload = JSON.build do |j|
        j.object do
          j.field "user" do
            j.object do
              j.field "id", message[:creator_id]
              j.field "name", message[:creator_name]
            end
          end
          j.field "room" do
            j.object do
              j.field "id", message[:room_id]
              j.field "name", message[:room_name]
              j.field "path", "/rooms/#{message[:room_id]}/#{hook[:user_id]}-#{hook[:bot_token]}/messages"
            end
          end
          j.field "message" do
            j.object do
              j.field "id", message[:id]
              j.field "body" do
                j.object do
                  j.field "html", body
                  j.field "plain", MessageCreator.plain_text(body)
                end
              end
              j.field "path", "/rooms/#{message[:room_id]}/@#{message[:id]}"
            end
          end
        end
      end

      url = URI.parse(hook[:url].to_s)
      if !{"http", "https"}.includes?(url.scheme) || url.user || url.password
        raise "invalid webhook URL"
      end

      reply_text = deliver_webhook(url, payload)
      if reply_text
        webhook_reply(hook[:user_id], message[:room_id], reply_text)
      end
    rescue IO::TimeoutError
      if hook && message
        webhook_reply(hook[:user_id], message[:room_id],
          "Failed to respond within 7 seconds")
      end
    end

    # POST JSON; ответ 200 + text/* → текст-реплай от бота, иначе nil.
    def self.deliver_webhook(url : URI, payload : String) : String?
      client = HTTP::Client.new(url)
      client.connect_timeout = 7.seconds
      client.read_timeout = 7.seconds
      response = client.post(url.request_target.not_nil!,
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: payload)
      content_type = response.headers["Content-Type"]?.to_s.split(";").first?
      if response.status_code == 200 &&
         {"text/plain", "text/html"}.includes?(content_type) &&
         !response.body.empty?
        response.body
      end
    end

    # Ответ бота — сообщение от его имени (webhooks: false — как
    # notifyMessage(result, { webhooks: false }) у express).
    def self.webhook_reply(bot_id : Int64, room_id : Int64, text : String) : Nil
      room = Room.find?(room_id)
      bot = User.find?(bot_id)
      return unless room && bot
      body_html = "<p>#{HTML.escape(text)}</p>"
      MessageCreator.create!(room, bot, body_html, UUID.random.to_s,
        webhooks: false)
    end
  end
end
