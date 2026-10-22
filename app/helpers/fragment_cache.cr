# Per-worker fragment cache готовых DOM-фрагментов сообщений — порт
# Rails fragment caching референса (app/models/fragment_cache.rb +
# `render partial:, collection:, cached:` в rooms/show.html.erb):
# фрагмент кэшируется по cache_key_with_version (id + updated_at) и
# живёт один DB-epoch, как PageCache. Попадание убирает из рендера и
# SQL (тело rich text, автор), и сам рендер DOM: комнаты и авторы
# догружаются одним IN-запросом на сущность только по промахам.
#
# Свежесть: правка сообщения меняет messages.updated_at (ключ меняется,
# см. MessagesController#update); всё остальное (профиль автора,
# переименование комнаты, любые иные записи) покрывает epoch —
# собственные write-экшены сбрасывают кэш через PageCache.invalidate!,
# чужие коммиты двигают PRAGMA data_version.
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

    # cache_key_with_version: "messages/<id>-<updated_at_ms>" (Rails:
    # "messages/1-20240601120000000123"). Версия рендера в ключе: смена
    # пайплайна (например подключение HtmlSanitizer) сбрасывает кэш,
    # чтобы отравленные допатчные фрагменты не доживали свой epoch.
    RENDER_VERSION = "s1"

    def self.key(m : Message) : String
      updated = m.updated_at || m.created_at || Time.utc
      "messages/#{m.id.not_nil!}-#{updated.to_unix_ms}-#{RENDER_VERSION}"
    end

    def self.get(key : String, epoch : String) : String?
      if epoch != @@epoch
        @@entries.clear
        @@bytes = 0
        @@epoch = epoch
        return nil
      end
      # LRU: переставить в конец (Hash хранит порядок вставки)
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

    # Все операции над @@entries — чистая память без yield-точек,
    # атомарны между переключениями фибр (SQL в ChatLayout.messages_to
    # выполняется до мутаций, а set сверяет epoch после).
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

# Короткое имя для ChatLayout (FragmentCache.key / .get / .set).
FragmentCache = Campfire::FragmentCache
