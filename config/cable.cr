# Cable/Turbo-клей приложения (аналог turbo-rails engine + ActionCable
# ::Engine): ключ подписи стримов из secret_key_base, единый cable-сервер,
# монтаж /cable через railties-seam (Application#cable_handler).
require "action_cable_cr"
require "turbo_cr"

Turbo.app = "campfire" # gid://campfire/<Model>/<id>

if (secret = CRails.secret_key_base)
  Turbo.signed_stream_verifier_key_from_secret!(secret)
end

# Broadcast через сервер = локальная доставка кабелем + ретрансляция
# воркерам кластера через CableBus (эквивалент PG/Redis-pubsub
# ActionCable референса, доставляющего всем воркерам). Так один и тот
# же транспорт получают и Campfire.broadcast, и turbo_cr Broadcasts
# (Turbo.cable.broadcast), и presence-канал (ActionCable.server).
# Кадры, пришедшие ПО шине, CableBus доставляет в pubsub напрямую,
# не через #broadcast — иначе ретрансляция зациклилась бы.
class CampfireCable < ActionCable::Server
  def broadcast(stream_name : String, message : String) : Nil
    pubsub.broadcast(stream_name, message)
    Campfire::CableBus.relay(stream_name, message)
  end
end

campfire_cable = CampfireCable.new
ActionCable.server = campfire_cable
Turbo.cable_server = campfire_cable
CRails.application.cable_handler = campfire_cable.ws_handler
