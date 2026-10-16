# GET /rails/active_storage/blobs/redirect/:token/:filename и
# .../representations/redirect/:token/:variation/:filename — отдача
# вложений сообщений (порт storage.js registerStorage): подпись blob_id
# верификатором с salt "ActiveStorage" (purpose blob_id/variation),
# авторизация как authorizedBlob (membership комнаты сообщения),
# servingAttributes (inline для картинок, attachment для остального).
# Representation-путь отдаёт оригинальный файл: ресайз-варианты не
# портированы (нет vips/sharp) — сид-картинки и так в разрешении ≤1200.
class ActiveStorageController < ApplicationController
  # content-types, которые Rails отдаёт как octet-stream/attachment.
  BINARY_TYPES = {
    "text/html", "image/svg+xml", "application/postscript",
    "application/x-shockwave-flash", "text/xml", "application/xml",
    "application/xhtml+xml", "application/mathml+xml", "text/cache-manifest",
  }
  INLINE_TYPES = {
    "image/webp", "image/avif", "image/png", "image/gif", "image/jpeg",
    "image/tiff", "image/bmp", "image/vnd.adobe.photoshop",
    "image/vnd.microsoft.icon", "application/pdf",
  }

  def blob
    serve_common(representation: false)
  end

  def representation
    serve_common(representation: true)
  end

  private def serve_common(representation : Bool) : Nil
    user = current_user
    return render(plain: "unauthorized", status: 401) unless user

    blob_record = find_authorized_blob(params["token"].to_s, user)
    return render(plain: "not found", status: 404) unless blob_record

    if representation
      variation = storage_verifier.verified_any(params["variation"].to_s,
        purpose: "variation")
      return render(plain: "not found", status: 404) unless variation
    end

    key = blob_record.key.to_s
    path = File.join(storage_root, key[0, 2], key[2, 2], key)
    return render(plain: "file missing", status: 404) unless File.exists?(path)

    content_type, disposition = serving_attributes(
      blob_record.content_type.to_s, params["disposition"]?.to_s)
    response.headers["Content-Disposition"] =
      %(#{disposition}; filename="#{blob_record.filename.to_s.gsub('"', "")}")
    response.headers["Cache-Control"] = "private, max-age=300"
    render(html: File.read(path), content_type: content_type)
  end

  # Верификатор с salt "ActiveStorage" (sha1, как rails.js sign по
  # умолчанию; urlsafe — токены в path).
  private def storage_verifier
    CRails.application.message_verifier("ActiveStorage",
      digest: :sha1, url_safe: true)
  end

  private def find_authorized_blob(token : String, user : User) : ActiveStorageBlob?
    blob_id = storage_verifier.verified_any(token, purpose: "blob_id")
      .try(&.as_i?)
    return nil unless blob_id
    blob = ActiveStorageBlob.find?(blob_id.to_i64)
    return nil unless blob
    authorized_blob?(blob, user) ? blob : nil
  end

  # authorizedBlob (storage.js): вложение на User/Account — публично;
  # на Message/ActionText::RichText — членство в комнате сообщения;
  # без вложений — владелец из metadata.campfire_upload_user_id.
  private def authorized_blob?(blob : ActiveStorageBlob, user : User) : Bool
    conn = ActiveRecord::Base.connection
    attachments = conn.query_all(
      "SELECT record_type, record_id FROM active_storage_attachments WHERE blob_id = ?",
      args: [blob.id.not_nil!], as: {String, Int64})
    if attachments.empty?
      metadata = JSON.parse(blob.metadata.to_s.presence || "{}")
      owner = metadata["campfire_upload_user_id"]?.try(&.as_i?)
      owner.nil? || owner == user.id
    else
      attachments.any? do |record_type, record_id|
        case record_type
        when "User", "Account" then true
        when "Message", "ActionText::RichText"
          message_id = record_type == "Message" ? record_id : conn.query_one?(
            "SELECT record_id FROM action_text_rich_texts WHERE id = ? AND record_type = 'Message'",
            record_id, as: Int64)
          next false unless message_id
          !conn.query_one?(
            %(SELECT m.id FROM messages m JOIN memberships ms ON ms.room_id = m.room_id
              WHERE m.id = ? AND ms.user_id = ?),
            message_id, user.id.not_nil!, as: Int64).nil?
        else false
        end
      end
    end
  end

  # servingAttributes (storage.js).
  private def serving_attributes(raw_type : String, disposition : String) : {String, String}
    type = raw_type.split(";")[0].downcase
    return {"application/octet-stream", "attachment"} if BINARY_TYPES.includes?(type)
    inline = INLINE_TYPES.includes?(type) && disposition != "attachment"
    {type.presence || "application/octet-stream", inline ? "inline" : "attachment"}
  end

  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end
end
