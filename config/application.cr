require "active_storage_cr"

require "../app/middleware/public_cache"

# Disk-сервис сообщений: root как у гема (CAMPFIRE_STORAGE_ROOT ||
# storage), fan-out путь key[0,2]/key[2,2]/key как в DiskService
# референса — в шарде (Iteration 8) путь пока плоский; подкласс здесь,
# чтобы старые файлы и контроллер отдачи видели одну раскладку.
class CampfireDiskService < ActiveStorage::DiskService
  def path_for(key : String) : String
    raise ArgumentError.new("unsafe key: #{key}") if key.includes?("..")
    File.join(@root, key[0, 2], key[2, 2], key)
  end
end

ActiveStorage.service = CampfireDiskService.new(
  ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage", "local")

# Как референс (Rails 8, дефолт :vips): варианты через libvips.
ActiveStorage.variant_processor = :vips

class Application < CRails::Application
end

CRails.application = Application.new

# Как config/initializers/assets.rb Rails-версии (assets.version = "1.0").
CRails.application.config.assets.version = "1.0"

# Публичные ответы (аватар по signed-токену) — из памяти до
# RequestId/RequestLogger/маршрутизации (аналог front-кэша Thruster;
# заполняет AvatarsController, см. app/middleware/public_cache.cr).
CRails.application.config.middleware.insert_before(CRails::Middleware::RequestId, PublicCache)
