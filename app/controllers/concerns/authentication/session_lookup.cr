module Authentication
  module SessionLookup
    def find_session_by_cookie : Campfire::IdentityCache::Entry?
      raw = cookies.signed["session_token"]?
      token = Session.token_from_signed_jar(raw)
      return nil unless token
      Campfire::IdentityCache.lookup(token, db_epoch)
    end
  end
end
