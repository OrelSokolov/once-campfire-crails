require "./authentication/session_lookup"

module ActiveStorageAuthentication
  include Authentication::SessionLookup

  private def require_active_storage_authentication : Nil
    head(:unauthorized) unless find_session_by_cookie.try(&.session)
  end
end
