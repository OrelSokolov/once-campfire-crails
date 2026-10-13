# Cable/Turbo-клей приложения (аналог turbo-rails engine + ActionCable
# ::Engine): ключ подписи стримов из secret_key_base, единый cable-сервер,
# монтаж /cable через railties-seam (Application#cable_handler).
require "action_cable_cr"
require "turbo_cr"

Turbo.app = "campfire" # gid://campfire/<Model>/<id>

if (secret = CRails.secret_key_base)
  Turbo.signed_stream_verifier_key_from_secret!(secret)
end

campfire_cable = ActionCable::Server.new
ActionCable.server = campfire_cable
Turbo.cable_server = campfire_cable
CRails.application.cable_handler = campfire_cable.ws_handler
