class Accounts::LogosController < ApplicationController
  skip_before_action :require_authentication, only: [:show]

  def show
    account = Account.take
    blob = account.try(&.logo_blob)
    small = params["size"]? == "small"

    etag = %(W/"account-logo-#{blob.try(&.key) || stock_icon(small)}")
    response.headers["Cache-Control"] =
      "public, max-age=300, stale-while-revalidate=604800"
    response.headers["ETag"] = etag
    if request.headers["If-None-Match"]? == etag
      return render(plain: "", status: :not_modified)
    end

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

  def destroy
    Campfire::ResponseCache.invalidate!
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
    redirect_to edit_account_url
  end

  private def stock_icon(small : Bool) : String
    ChatLayout.asset(small ? "logos/app-icon-192.png" : "logos/app-icon.png")
  end

  # storage/files/<key[0,2]>/<key[2,2]>/<key>
  private def storage_path(key : String) : String
    File.join(storage_root, key[0, 2], key[2, 2], key)
  end

  # Variant cache dir: storage/files/<fan-out>/variants/<key> (DiskService#path_for layout).
  private def variants_dir(key : String) : String
    File.dirname(storage_path("variants/#{key}/x"))
  end

  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end
end
