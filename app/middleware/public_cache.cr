require "http"

# Short-circuit for public responses, the port's analogue of Thruster's front
# cache (crates/kit/src/front/cache.rs of the Rust port): a GET on a public
# avatar token path is served from memory before RequestId/RequestLogger/
# routing/PRAGMA data_version/signature verification — the request costs about
# as much as a static file.
#
# The cache is filled by AvatarsController (its response is already fully in
# memory): the stdlib Response API gives middleware no way to tee another
# handler's body (a framework-level feature, see PLAN.md roadmap).
#
# Freshness is TTL from Cache-Control, like an HTTP cache and the Rust front:
# no PRAGMA/epoch here on purpose — an avatar change may stay invisible up to
# max-age (30 minutes), exactly the semantics the header itself gives browsers.
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
    TTL = 30.minutes # expires_in 30.minutes, public: true

    def self.budget : Int32
      mb = ENV["CAMPFIRE_PUBLIC_CACHE_MB"]?.try(&.to_i?) || 16
      mb.clamp(0, 256) * 1024 * 1024
    end

    @@entries = {} of String => Entry
    @@bytes = 0

    AVATAR_PATH = /^\/users\/([^\/]+)\/avatar$/

    # Public (viewer-independent) path: a signed_id token, not a numeric id
    # (numeric ids are session-dependent and must not be cached publicly).
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
          @@entries[key] = entry # LRU: move to the end
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

    # Pure memory work with no yield points — atomic between fibers.
    private def self.evict : Nil
      while @@bytes > budget && @@entries.size > 1
        oldest = @@entries.each_key.next.as(String)
        if (entry = @@entries.delete(oldest))
          @@bytes -= entry.cost + oldest.bytesize
        end
      end
    end

    # HEAD/Range take the full path (middleware serves no body for HEAD,
    # Range is not cacheable by definition).
    def call(context)
      request = context.request
      if request.get? && !request.headers["Range"]? &&
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

# Short alias for controllers/config.
PublicCache = Campfire::PublicCache
