# Per-worker кэш аутентификации: session + user по токену из signed
# cookie — убирает 2 SQL (Session.where + User.find?) с каждого
# аутентифицированного запроса. Гарантии свежести — те же, что у
# PageCache: записи живут ровно один DB-epoch (PRAGMA data_version
# двигается на коммиты любых других соединений/процессов), а собственные
# write-экшены сбрасывают кэш через PageCache.invalidate!.
#
# Негативные результаты (токен не найден) не кэшируются — битый токен
# всегда перепроверяется, чтобы ошибочный nil не «залип» до epoch.
module Campfire
  class IdentityCache
    class Entry
      getter session : Session
      getter user : User?

      def initialize(@session, @user)
      end
    end

    LIMIT = 4096

    @@entries = {} of String => Entry
    @@epoch = ""

    # Как и в PageCache: мутации @@entries — чистая память без
    # yield-точек, атомарны между переключениями фибр; SQL-чтения
    # выполняются ДО мутаций, а перед записью epoch перепроверяется
    # (за время SQL другая фибра могла сбросить кэш).
    def self.lookup(token : String, epoch : String) : Entry?
      if epoch != @@epoch
        @@entries.clear
        @@epoch = epoch
      end
      if (entry = @@entries.delete(token))
        @@entries[token] = entry # LRU: переставить в конец
        return entry
      end
      session = Session.where("token = ?", token).take
      return nil unless session
      user = session.user_id ? User.find?(session.user_id.not_nil!) : nil
      entry = Entry.new(session, user)
      if epoch == @@epoch
        @@entries.clear if @@entries.size >= LIMIT
        @@entries[token] = entry
      end
      entry
    end

    def self.reset! : Nil
      @@entries.clear
      @@epoch = ""
    end
  end
end
