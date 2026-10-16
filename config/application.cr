require "../app/middleware/public_cache"

class Application < CRails::Application
end

CRails.application = Application.new

# Как config/initializers/assets.rb Rails-версии (assets.version = "1.0").
CRails.application.config.assets.version = "1.0"

# Публичные ответы (аватар по signed-токену) — из памяти до
# RequestId/RequestLogger/маршрутизации (аналог front-кэша Thruster;
# заполняет AvatarsController, см. app/middleware/public_cache.cr).
CRails.application.config.middleware.insert_before(CRails::Middleware::RequestId, PublicCache)
