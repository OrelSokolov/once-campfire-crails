# Порт once-campfire/app/models/current.rb: глобальные per-request
# атрибуты. Значения живут в классе (ActiveSupport::CurrentAttributes,
# сброс между запросами — диспетчером railties_cr), сессия/юзер
# заполняются ApplicationController (аналог concerns/authentication.rb:
# authenticated_as / bot_authentication), request — before_action
# :set_current_request (concerns/set_current_request.rb).
#
# Отклонение от Rails: атрибуты типизированы (Crystal), кастомный
# writer `session=` (проставляющий user) заменён явной установкой обоих
# атрибутов в ApplicationController.
class Current < ActiveSupport::CurrentAttributes
  attribute session: Session?, user: User?, request: HTTP::Request?

  def self.request_host : String?
    request.try(&.host)
  end

  def self.request_protocol : String?
    request.try(&.scheme)
  end

  def self.account : Account?
    Account.first
  end
end
