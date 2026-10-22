abstract class ApplicationController < ActionController::Base
  include ViewHelpers

  include Authentication
  include Authorization
  include SetCurrentRequest
  include TrackedRoomVisit
  include CachedResponses
  include BlockBannedRequests

  # turbo-rails engine.rb подключает Turbo::Streams::Broadcasts в
  # ActionController::Base — контроллеры зовут broadcast_*_to напрямую
  # (транспорт: Turbo.cable = CampfireCable, тот же, что у Campfire.broadcast).
  include Turbo::Streams::Broadcasts

  before_action :set_current_request
  before_action :reject_banned_ip
  before_action :require_authentication

  # Campfire authentication.rb: protect_from_forgery using: :header_only,
  # with: :exception — Sec-Fetch-Site-защита Rails 8.2 (без токенов в
  # формах), бот-ключи в URL (не из браузера) защиту отключают.
  protect_from_forgery using: :header_only, with: :exception, unless: :bot_request?

  # Оракул (rails-main, lazy-сессии): protect_against_forgery? в контексте
  # рендера false → формы НЕ содержат embedded authenticity_token (ни у
  # анонимов, ни у залогиненных — проверено живым оракулом, /session/new и
  # /account/edit). Turbo/XHR берут токен из csrf_meta_tags; верификация —
  # Sec-Fetch-Site (header_only), от поля в форме не зависит.
  protected def __csrf_token_field(action : String, method : String) : String
    ""
  end
end
