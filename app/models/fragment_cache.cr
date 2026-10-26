require "compress/gzip"
require "digest/sha1"

# Native view caches share one byte budget across every database generation.
module Campfire
  class FragmentCache
    OVERHEAD = 256

    def self.budget : Int32
      mb = ENV["CAMPFIRE_FRAGMENT_CACHE_MB"]?.try(&.to_i?) || 32
      mb.clamp(0, 1024) * 1024 * 1024
    end

    @@entries = {} of String => String
    @@bytes = 0
    @@epoch = ""

    # Render version in the key: changing the render pipeline (e.g. enabling HtmlSanitizer)
    # resets the cache so stale patched fragments don't outlive their epoch.
    RENDER_VERSION = "s2"

    def self.key(m : Message) : String
      updated = m.updated_at || m.created_at || Time.utc
      "messages/#{m.id!}-#{updated.to_unix_ms}-#{RENDER_VERSION}"
    end

    def self.get(key : String, epoch : String) : String?
      if epoch != @@epoch
        @@entries.clear
        @@bytes = 0
        @@epoch = epoch
        return nil
      end
      # LRU: move to the back (Hash keeps insertion order).
      if (html = @@entries.delete(key))
        @@entries[key] = html
        html
      end
    end

    def self.set(key : String, epoch : String, html : String) : Nil
      return if epoch != @@epoch || budget == 0
      return if html.bytesize > budget // 8 || key.bytesize > 512
      if (replaced = @@entries.delete(key))
        @@bytes -= replaced.bytesize + key.bytesize + OVERHEAD
      end
      @@entries[key] = html
      @@bytes += html.bytesize + key.bytesize + OVERHEAD
      evict
    end

    def self.reset! : Nil
      @@entries.clear
      @@bytes = 0
      @@epoch = ""
    end

    # Pure in-memory mutations with no yield points, atomic across fiber switches.
    private def self.evict : Nil
      while @@bytes > budget && @@entries.size > 1
        oldest = @@entries.each_key.next.as(String)
        if (html = @@entries.delete(oldest))
          @@bytes -= html.bytesize + oldest.bytesize + OVERHEAD
        end
      end
    end
  end
end

# Short alias for ChatLayout (FragmentCache.key / .get / .set).
FragmentCache = Campfire::FragmentCache
