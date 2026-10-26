require "active_storage_cr"

require "../app/middleware/public_cache"

# Disk-сервис сообщений: root как у гема (CAMPFIRE_STORAGE_ROOT ||
# storage), fan-out путь key[0,2]/key[2,2]/key — в DiskService шарда
# (с analyzer-итерации v0.1.3), подкласс здесь больше не нужен.
ActiveStorage.service = ActiveStorage::DiskService.new(
  ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage", "local")

# Как референс (Rails 8, дефолт :vips): варианты через libvips.
ActiveStorage.variant_processor = :vips

# Семантика форм как Rails load_defaults 6.1+/8.x (оракул once-campfire):
# локальные формы без data-remote, генерация ids полей, без
# utf8-enrollment (form_with в views/** теперь через ActionView-хелперы);
# _method-hidden и прочие hidden-инпуты без autocomplete="off"
# (load_defaults 8.2: remove_hidden_field_autocomplete).
ActionView::Helpers::FormHelper.form_with_generates_remote_forms = false
ActionView::Helpers::FormHelper.form_with_generates_ids = true
ActionView::Helpers::FormTagHelper.default_enforce_utf8 = false
ActionView::Helpers::FormTagHelper.method_field_autocomplete = false
ActionView::Helpers::FormTagHelper.remove_hidden_field_autocomplete = true


class Application < CRails::Application
end

CRails.application = Application.new

# Как config/initializers/assets.rb Rails-версии (assets.version = "1.0").
CRails.application.config.assets.version = "1.0"

# Публичные ответы (аватар по signed-токену) — из памяти до
# RequestId/RequestLogger/маршрутизации (аналог front-кэша Thruster;
# заполняет AvatarsController, см. app/middleware/public_cache.cr).
CRails.application.config.middleware.insert_before(CRails::Middleware::RequestId, PublicCache)
