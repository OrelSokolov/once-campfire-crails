require "./authentication/session_lookup"

# active_storage_authentication.rb: guard для ActiveStorage-путей
# представления (logo/аватары) — сессия по cookie без общего
# require_authentication (публичные токен-линки обрабатывает сам
# контроллер).
module ActiveStorageAuthentication
  include Authentication::SessionLookup

  private def require_active_storage_authentication : Nil
    head(:unauthorized) unless find_session_by_cookie.try(&.session)
  end
end
