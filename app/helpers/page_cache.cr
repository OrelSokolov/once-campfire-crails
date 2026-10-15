require "compress/gzip"
require "digest/sha1"

# Whole-page response cache per-worker — порт response_cache.js
# (once-campfire-express): byte-bounded LRU готовых HTML-страниц;
# записи валидны ровно один DB-epoch (PRAGMA data_version меняется при
# коммитах любого другого соединения — HTTP-писатели, jobs-воркер,
# другие процессы), первый lookup под новым epoch дропает всё.
# Страница кэшируется вместе с ETag; gzip-представление лениво.
module Campfire
  class PageCache
    class Page
      getter bytes : String
      getter etag : String
      property gzipped : String?
      property cost : Int32 = 0
      property cache_key : String = ""

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

    # Все операции над @@entries — чистая память без yield-точек,
    # атомарны между переключениями фибр.
    #
    # Инвалидация: PRAGMA data_version двигается только на ЧУЖИЕ коммиты
    # (другие соединения/процессы); собственные записи приложения через пул
    # не видны — поэтому каждый write-экшен зовёт invalidate! явно.
    # Сбрасывает и IdentityCache (session+user могли измениться тем же
    # write-экшеном: профиль, аккаунт, membership), и FragmentCache
    # (профиль автора и комнаты влияют на DOM фрагментов).
    def self.invalidate! : Nil
      @@epoch = ""
      Campfire::IdentityCache.reset!
      Campfire::FragmentCache.reset!
    end

    def self.epoch : String
      conn = ActiveRecord::Base.connection
      conn.query_one("PRAGMA data_version") { |rs| rs.read(Int64) }.to_s
    rescue
      # при любой проблеме считаем эпоху сменившейся — кэш сбрасывается
      Random::Secure.hex(8)
    end

    # Ключ: всё, от чего могут зависеть байты страницы, кроме БД
    # (БД покрывается epoch): handler, полный URL, заголовки, которые
    # читает рендер, viewer.
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
      # LRU: переставить в конец (Hash хранит порядок вставки)
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

# Короткое имя для контроллеров (PageCache.epoch / PageCache.key / ...).
PageCache = Campfire::PageCache
