# Port of the oracle's app/models/record_cache.rb: request-local records
# from bounded, immutable database snapshots. The oracle serializes
# attributes into FragmentCache.store; here snapshots are the per-worker
# objects themselves: read paths treat records as immutable, and freshness
# comes from the same guarantee as ResponseCache/IdentityCache — one
# DB-epoch (PRAGMA data_version moves on commits from other connections;
# write actions reset the cache via ResponseCache.invalidate!).
#
# The key embeds the version (the request's db_epoch); a hit is
# additionally re-validated against a fresh epoch — the observer must see
# the same epoch as at snapshot time (same as cache_page). Negative
# results (nil inside the array) are not cached — like the oracle
# (record&.persisted?).
class RecordCache
  LIMIT = 4096

  @@entries = {} of String => Array(ActiveRecord::Base?)
  @@epoch = ""

  def self.fetch(key : Array(String), version : String?, & : -> Array(ActiveRecord::Base?)) : Array(ActiveRecord::Base?)
    return yield unless version && PageCache.budget > 0
    cache_key = String.build do |io|
      io << "record-snapshot-v1\0" << version
      key.each { |part| io << "\0" << part }
    end
    if version != @@epoch
      @@entries.clear
      @@epoch = version
    end
    if (records = @@entries.delete(cache_key))
      @@entries[cache_key] = records # LRU: move to the end
      return records if PageCache.epoch == version
      records
    else
      records = yield
      if records.all?(&.try(&.persisted?)) && PageCache.epoch == version
        @@entries.clear if @@entries.size >= LIMIT
        @@entries[cache_key] = records
      end
      records
    end
  end

  def self.reset! : Nil
    @@entries.clear
    @@epoch = ""
  end
end
