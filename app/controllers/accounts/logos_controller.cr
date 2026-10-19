# GET/DELETE /account/logo — порт Accounts::LogosController
# (app/controllers/accounts/logos_controller.rb): layouts/
# application.html.erb линкует fresh_account_logo как rel=icon и
# apple-touch-icon. show публичен (allow_unauthenticated_access) — браузер
# запрашивает иконку без сессии. Варианты :large(512)/:small(192) — через
# logo_variant (png, кеш variants/<key>/… на диске); nil (нет вложения /
# не-variable / ошибка обработки) — стоковая logos/app-icon.png пребилда.
class Accounts::LogosController < ApplicationController
  skip_before_action :require_authentication, only: [:show]

  def show
    account = Account.take
    blob = account.try(&.logo_blob)
    small = params["size"]? == "small"

    # stale?(etag: Current.account) + expires_in 5.minutes, public: true,
    # stale_while_revalidate: 1.week (версия — ключ блоба либо дайджест
    # стоковой иконки пребилда).
    etag = %(W/"account-logo-#{blob.try(&.key) || stock_icon(small)}")
    response.headers["Cache-Control"] =
      "public, max-age=300, stale-while-revalidate=604800"
    response.headers["ETag"] = etag
    if request.headers["If-None-Match"]? == etag
      return render(plain: "", status: :not_modified)
    end

    # logo_variant(logo_size) → send_png_file path_for(variant.key).
    if (variant = account.try(&.logo_variant(small ? "small" : "large")))
      service = ActiveStorage.service
      if service.is_a?(ActiveStorage::DiskService) &&
         (path = service.path_for(variant.key)) && File.exists?(path)
        return render(html: File.read(path), content_type: "image/png")
      end
    end

    file = File.join("public", stock_icon(small))
    return render(plain: "stock logo missing", status: 404) unless File.exists?(file)
    render(html: File.read(file), content_type: "image/png")
  end

  # ensure_can_administer + Current.account.logo.destroy: purge вложения
  # (attachment + вариантные записи + blob + файлы — оригинал и кешированные
  # варианты variants/<key>/* на диске) и редирект в настройки.
  def destroy
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    return render(plain: "forbidden", status: 403) unless user.role == 1
    if (attachment = Account.take.try(&.logo_attachment))
      blob_id = attachment.blob_id
      attachment.destroy
      if (bid = blob_id) && (blob = ActiveStorageBlob.find?(bid))
        ActiveRecord::Base.connection.exec(
          "DELETE FROM active_storage_variant_records WHERE blob_id = ?", blob.id.not_nil!)
        blob.destroy
        if (key = blob.key)
          Dir.glob(File.join(variants_dir(key), "*")).each { |f| File.delete?(f) }
          File.delete?(storage_path(key))
        end
      end
    end
    redirect_to edit_account_path
  end

  # Стоковая иконка (send_stock_icon): app-icon-192.png для :small,
  # иначе app-icon.png — дайджест-путь пребилда референса.
  private def stock_icon(small : Bool) : String
    ChatLayout.asset(small ? "logos/app-icon-192.png" : "logos/app-icon.png")
  end

  # storage/files/<key[0,2]>/<key[2,2]>/<key> (см. Users::AvatarsController).
  private def storage_path(key : String) : String
    File.join(storage_root, key[0, 2], key[2, 2], key)
  end

  # Каталог кеша вариантов блоба: storage/files/<fan-out>/variants/<key>
  # (раскладка CampfireDiskService.path_for).
  private def variants_dir(key : String) : String
    File.dirname(storage_path("variants/#{key}/x"))
  end

  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end
end
