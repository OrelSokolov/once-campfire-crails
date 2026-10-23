# authentication/session_lookup.rb: сессия по signed cookie
# session_token (IdentityCache + DB-epoch) — без Current-сайд-эффектов
# (их делает Authentication#current_session).
module Authentication
  module SessionLookup
    def find_session_by_cookie : Campfire::IdentityCache::Entry?
      raw = cookies.signed["session_token"]?
      token = case raw
              when String then raw
              when JSON::Any then raw.as_s? # signed jar decodes JSON-wrapped values
              else nil
              end
      return nil unless token
      Campfire::IdentityCache.lookup(token, db_epoch)
    end
  end
end
