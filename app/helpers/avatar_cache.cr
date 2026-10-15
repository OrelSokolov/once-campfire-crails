# Кэш avatar-ответов per-worker: signed-токен → готовые байты (файл
# аватара или SVG-инициалы) + Content-Type. Инвалидация — DB-эпоха
# (PRAGMA data_version, см. PageCache): смена аватара/профиля — чужой
# коммит, эпоха меняется, первый lookup под новой эпохой дропает всё.
# Ключи blob'ов контентно-адресованы, перезапись файла по тому же ключу
# невозможна — кэшировать байты файла по токену безопасно.
module Campfire
  class AvatarCache
    class Entry
      getter bytes : String
      getter content_type : String
      property cost : Int32 = 0

      def initialize(@bytes : String, @content_type : String)
      end
    end

    OVERHEAD = 256

    # Отдельный от PageCache бюджет: аватары — маленькие бинарники
    # (десятки КБ), 16 МБ хватает на сотни пользователей.
    def self.budget : Int32
      mb = ENV["CAMPFIRE_AVATAR_CACHE_MB"]?.try(&.to_i?) || 16
      mb.clamp(0, 256) * 1024 * 1024
    end

    @@entries = {} of String => Entry
    @@bytes = 0
    @@epoch = ""

    # Операции над @@entries — чистая память без yield-точек (как PageCache).
    def self.get(key : String, epoch : String) : Entry?
      if epoch != @@epoch
        @@entries.clear
        @@bytes = 0
        @@epoch = epoch
        return nil
      end
      entry = @@entries[key]?
      return nil unless entry
      # LRU: переставить в конец (Hash хранит порядок вставки)
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

# Короткое имя для контроллеров.
AvatarCache = Campfire::AvatarCache
