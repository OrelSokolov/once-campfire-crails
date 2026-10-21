require "http"

# Короткое замыкание публичных ответов — аналог front-кэша Thruster
# (crates/kit/src/front/cache.rs Rust-порта): GET на публичный токен-путь
# аватара отдаётся из памяти ДО RequestId/RequestLogger/маршрутизации/
# PRAGMA data_version/верификации подписи — цена запроса падает до уровня
# статики.
#
# Кэш заполняет AvatarsController (ответ и так целиком в памяти):
# перехватывать тело чужого ответа в middleware stdlib-Response не даёт
# API (нужен tee-выход — это уровень фреймворка, см. PLAN.md roadmap).
#
# Свежесть — TTL из Cache-Control, как у HTTP-кэша и Rust-фронта:
# PRAGMA/epoch тут НЕТ намеренно, смена аватара видна до max-age
# (30 минут) — ровно та же семантика, что отдаёт браузеру сам заголовок.
module Campfire
  class PublicCache
    include HTTP::Handler

    class Entry
      attr_reader body : String
      attr_reader content_type : String
      attr_reader cache_control : String
      attr_reader expires_at : Time::Instant

      def initialize(@body, @content_type, @cache_control, ttl : Time::Span)
        @expires_at = Time.instant + ttl
      end

      def cost : Int32
        @body.bytesize + OVERHEAD
      end
    end

    OVERHEAD = 256
    TTL = 30.minutes # expires_in 30.minutes, public: true (референс)

    def self.budget : Int32
      mb = ENV["CAMPFIRE_PUBLIC_CACHE_MB"]?.try(&.to_i?) || 16
      mb.clamp(0, 256) * 1024 * 1024
    end

    @@entries = {} of String => Entry
    @@bytes = 0

    AVATAR_PATH = /^\/users\/([^\/]+)\/avatar$/

    # Публичный (не зависящий от зрителя) путь: signed_id-токен, не
    # числовый id (числовой — только для авторизованных, зависит от
    # сессии, кэшировать публично нельзя).
    def self.avatar_token_path?(path : String) : String?
      if (match = path.match(AVATAR_PATH)) && !match[1].matches?(/\A\d+\z/)
        match[1]
      end
    end

    def self.key(request : HTTP::Request) : String
      path = request.path
      query = request.query.to_s
      query.empty? ? path : "#{path}?#{query}"
    end

    def self.get(key : String) : Entry?
      if (entry = @@entries.delete(key))
        if entry.expires_at > Time.instant
          @@entries[key] = entry # LRU: переставить в конец
          entry
        else
          @@bytes -= entry.cost + key.bytesize
          nil
        end
      end
    end

    def self.set(key : String, body : String, content_type : String, cache_control : String = "public, max-age=1800") : Nil
      return if budget == 0
      return if body.bytesize > budget // 8 || key.bytesize > 4096
      if (replaced = @@entries.delete(key))
        @@bytes -= replaced.cost + key.bytesize
      end
      entry = Entry.new(body, content_type, cache_control, TTL)
      @@entries[key] = entry
      @@bytes += entry.cost + key.bytesize
      evict
    end

    # Чистая память без yield-точек — атомарно между фибрами.
    private def self.evict : Nil
      while @@bytes > budget && @@entries.size > 1
        oldest = @@entries.each_key.next.as(String)
        if (entry = @@entries.delete(oldest))
          @@bytes -= entry.cost + oldest.bytesize
        end
      end
    end

    # HEAD/Range уходят полным путём (без тела middleware не отвечает,
    # Range не кэшируется по определению).
    def call(context)
      request = context.request
      if request.method == "GET" && !request.headers["Range"]? &&
         PublicCache.avatar_token_path?(request.path) &&
         (entry = PublicCache.get(PublicCache.key(request)))
        response = context.response
        response.status_code = 200
        response.headers["Content-Type"] = entry.content_type
        response.headers["Cache-Control"] = entry.cache_control
        response.headers["X-Cache"] = "hit"
        response.print(entry.body)
        return
      end
      call_next(context)
    end
  end
end

# Короткое имя для контроллера/конфига.
PublicCache = Campfire::PublicCache
