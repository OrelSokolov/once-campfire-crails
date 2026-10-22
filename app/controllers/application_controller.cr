abstract class ApplicationController < ActionController::Base
  include ViewHelpers

  include Authentication
  include Authorization
  include SetCurrentRequest
  include TrackedRoomVisit
  include CachedResponses

  # turbo-rails engine.rb подключает Turbo::Streams::Broadcasts в
  # ActionController::Base — контроллеры зовут broadcast_*_to напрямую
  # (транспорт: Turbo.cable = CampfireCable, тот же, что у Campfire.broadcast).
  include Turbo::Streams::Broadcasts

  before_action :set_current_request
  before_action :require_authentication

  # Campfire authentication.rb: protect_from_forgery using: :header_only,
  # with: :exception — Sec-Fetch-Site-защита Rails 8.2 (без токенов в
  # формах), бот-ключи в URL (не из браузера) защиту отключают.
  protect_from_forgery using: :header_only, with: :exception, unless: :bot_request?
end
