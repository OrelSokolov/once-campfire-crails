# Per-worker cache of avatar responses: signed token -> ready bytes
# (avatar file or SVG initials) + Content-Type. Invalidation is the
# DB epoch (PRAGMA data_version, see PageCache). Blob keys are
# content-addressed, so caching file bytes by token is safe.
module Campfire
  class AvatarCache
    class Entry
      attr_reader bytes : String
      attr_reader content_type : String
      attr_accessor cost : Int32 = 0

      def initialize(@bytes : String, @content_type : String)
      end
    end

    OVERHEAD = 256

    # Budget separate from PageCache: avatars are small binaries.
    def self.budget : Int32
      mb = ENV["CAMPFIRE_AVATAR_CACHE_MB"]?.try(&.to_i?) || 16
      mb.clamp(0, 256) * 1024 * 1024
    end

    @@entries = {} of String => Entry
    @@bytes = 0
    @@epoch = ""

    # @@entries operations are pure memory with no yield points (as in PageCache).
    def self.get(key : String, epoch : String) : Entry?
      if epoch != @@epoch
        @@entries.clear
        @@bytes = 0
        @@epoch = epoch
        return nil
      end
      entry = @@entries[key]?
      return nil unless entry
      # LRU: move to the end (Hash keeps insertion order)
      @@entries.delete(key)
      @@entries[key] = entry
      entry
    end

    def self.set(key : String, epoch : String, bytes : String,
                 content_type : String) : Nil
      return if epoch != @@epoch || budget == 0
      entry = Entry.new(bytes, content_type)
      return if entry.bytes.bytesize > budget // 8 || key.bytesize > 4096
      if (replaced = @@entries.delete(key))
        @@bytes -= replaced.cost
      end
      entry.cost = entry.bytes.bytesize + key.bytesize + OVERHEAD
      @@entries[key] = entry
      @@bytes += entry.cost
      evict
    end

    private def self.evict : Nil
      while @@bytes > budget && @@entries.size > 1
        oldest = @@entries.each_key.next.as(String)
        if (entry = @@entries.delete(oldest))
          @@bytes -= entry.cost
        end
      end
    end
  end
end

# Short alias for controllers.
AvatarCache = Campfire::AvatarCache
