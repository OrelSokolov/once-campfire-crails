# Per-worker auth cache: session + user by signed-cookie token, saving
# 2 SQL queries per authenticated request. Freshness guarantees match
# PageCache: entries live for exactly one DB epoch (PRAGMA data_version
# moves on commits from any other connection/process — the observer
# connection sees this app's own writes too, no manual flushing).
# Negative results (token not found) are not cached.
module Campfire
  class IdentityCache
    class Entry
      attr_reader session : Session
      attr_reader user : User?

      def initialize(@session, @user)
      end
    end

    LIMIT = 4096

    @@entries = {} of String => Entry
    @@epoch = ""

    # As in PageCache: @@entries mutations are pure memory with no yield
    # points (atomic across fiber switches); SQL reads run BEFORE the
    # mutation and the epoch is rechecked before writing.
    def self.lookup(token : String, epoch : String) : Entry?
      if epoch != @@epoch
        @@entries.clear
        @@epoch = epoch
      end
      if (entry = @@entries.delete(token))
        @@entries[token] = entry # LRU: move to the end
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
