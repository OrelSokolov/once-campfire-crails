require "compress/gzip"
require "digest/sha1"

# A read-only observer sees commits from every writer, including other runtimes.
# PRAGMA data_version can only be compared on the same persistent connection.
module Campfire
  class ResponseCache
    class Page
      attr_reader bytes : String
      attr_reader etag : String
      attr_accessor gzipped : String?
      attr_accessor cost : Int32 = 0
      attr_accessor cache_key : String = ""

      def initialize(@bytes)
        @etag = %(W/") + Digest::SHA1.hexdigest(@bytes)[0, 24] + %(")
      end

      def gzip : String
        @gzipped ||= begin
          io = IO::Memory.new
          Compress::Gzip::Writer.open(io) { |gz| gz.print(@bytes) }
          io.to_s
        end
      end
    end

    OVERHEAD = 256

    def self.budget : Int32
      mb = ENV["CAMPFIRE_RESPONSE_CACHE_MB"]?.try(&.to_i?) || 64
      mb.clamp(0, 1024) * 1024 * 1024
    end

    @@entries = {} of String => Page
    @@bytes = 0
    @@epoch = ""
    @@observer : DB::Connection?
    # Fiber-safe semaphore for the leased (not fiber-safe) connection:
    # acquire = receive, release = send; created pre-primed, lazily.
    @@observer_lock : Channel(Bool)?

    private def self.observer_lock : Channel(Bool)
      @@observer_lock ||= begin
        ch = Channel(Bool).new(1)
        ch.send(true)
        ch
      end
    end

    # Pure in-memory mutations with no yield points, atomic across fiber switches.
    # The epoch comes from a dedicated read-only observer connection (the
    # oracle's ResponseCache): PRAGMA data_version only moves on commits from
    # OTHER connections, so the observer — which never writes — sees every
    # commit of this app, including the writer fiber's own. No manual
    # invalidate! in write actions: the epoch changes on the next read.
    def self.invalidate! : Nil
      @@epoch = ""
      Campfire::IdentityCache.reset!
      Campfire::FragmentCache.reset!
    end

    def self.epoch : String
      # The leased connection is not fiber-safe: serialize PRAGMA reads
      # (a quick, non-blocking query) instead of leasing per call.
      lock = observer_lock
      lock.receive
      begin
        observer.query_one("PRAGMA data_version") { |rs| rs.read(Int64) }.to_s
      rescue
        # On any failure treat the epoch as changed — the cache is dropped.
        Random::Secure.hex(8)
      ensure
        lock.send(true)
      end
    end

    private def self.observer : DB::Connection
      @@observer ||= ActiveRecord::Base.connection.checkout
    end

    # Key: everything the page bytes depend on besides the DB (covered by the epoch):
    # handler, full URL, headers read by rendering, viewer.
    def self.key(tag : String, request : HTTP::Request, user_id : Int64?) : String
      String.build do |io|
        io << tag << "\0"
        io << request.path << "?" << request.query.to_s << "\0"
        io << request.headers["Accept"]?.to_s << "\0"
        io << request.headers["Turbo-Frame"]?.to_s << "\0"
        io << request.headers["User-Agent"]?.to_s << "\0"
        io << request.headers["Cookie"]?.to_s << "\0"
        io << user_id.to_s
      end
    end

    def self.get(key : String, epoch : String) : Page?
      if epoch != @@epoch
        @@entries.clear
        @@bytes = 0
        @@epoch = epoch
        return nil
      end
      page = @@entries[key]?
      return nil unless page
      # LRU: move to the back (Hash keeps insertion order).
      @@entries.delete(key)
      @@entries[key] = page
      page
    end

    def self.set(key : String, epoch : String, page : Page) : Nil
      return if epoch != @@epoch || budget == 0
      return if page.bytes.bytesize > budget // 8 || key.bytesize > 8192
      if (replaced = @@entries.delete(key))
        @@bytes -= replaced.cost
      end
      page.cost = page.bytes.bytesize + (page.gzipped.try(&.bytesize) || 0) +
                  key.bytesize * 2 + OVERHEAD
      page.cache_key = key
      @@entries[key] = page
      @@bytes += page.cost
      evict
    end

    private def self.evict : Nil
      while @@bytes > budget && @@entries.size > 1
        oldest = @@entries.each_key.next.as(String)
        if (page = @@entries.delete(oldest))
          @@bytes -= page.cost
        end
      end
    end
  end
end

# Short alias for controllers (PageCache.epoch / PageCache.key / ...).
PageCache = Campfire::ResponseCache
