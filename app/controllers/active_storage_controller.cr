# Serves message attachments for the /rails/active_storage redirect routes (storage.js
# registerStorage): a signed blob_id token (salt "ActiveStorage"), authorizedBlob-style
# membership authorization, servingAttributes; image representations go through the
# shard's Variation with a variants/<key>/ cache, falling back to the original file.
class ActiveStorageController < ApplicationController
  include ActiveStorageAuthentication

  # Content types Rails serves as octet-stream/attachment.
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
    return head(:unauthorized) unless user

    blob_record = find_authorized_blob(params["token"].to_s, user)
    return render(plain: "not found", status: 404) unless blob_record

    variation : JSON::Any? = nil
    if representation
      unless (verified = storage_verifier.verified_any(params["variation"].to_s, purpose: "variation"))
        return render(plain: "not found", status: 404)
      end
      variation = verified
    end

    key = blob_record.key.to_s
    path = disk_path(key)
    ctype = blob_record.content_type.to_s
    if variation && (repr = representation_variant(blob_record, variation.not_nil!))
      path, ctype = repr
    end
    return render(plain: "file missing", status: 404) unless File.exists?(path)

    content_type, disposition = serving_attributes(ctype, params["disposition"]?.to_s)
    response.headers["Content-Disposition"] =
      %(#{disposition}; filename="#{blob_record.filename.to_s.gsub('"', "")}")
    response.headers["Cache-Control"] = "private, max-age=300"
    render(html: File.read(path), content_type: content_type)
  end

  # File path on the Disk service (the gem's DiskService#path_for).
  private def disk_path(key : String) : String
    service = ActiveStorage.service
    raise "active storage service is not disk-backed" unless service.is_a?(ActiveStorage::DiskService)
    service.path_for(key)
  end

  # Lazy variant processing (the gem's RepresentationsController#edit): transformations
  # from the signed variation token → Blob#representation (a vips variant for images, an
  # ffmpeg preview frame + variation for videos), cached on the service under
  # variants/<blob.key>/<variation.key> — the same key the eager post-time processing
  # writes, so this only runs when that failed or was skipped. nil means
  # processing failed → the original file.
  private def representation_variant(blob : ActiveStorage::Blob,
                                     variation : JSON::Any) : {String, String}?
    transformations = {} of String => ActiveStorage::Variation::Value
    variation.as_h.each do |name, value|
      transformations[name] = case raw = value.raw
        when String then raw
        when Array  then raw.map { |e| e.as_i.to_i32 }
        when Int64  then raw.to_i32
        else
          return nil
      end
    end
    repr = blob.representation(transformations)
    repr.processed
    {disk_path(repr.key), repr.content_type}
  rescue ex : Exception
    # vips/ffmpeg could not handle the file — the original (as before the shard).
    nil
  end

  # Verifier with salt "ActiveStorage", shared with ChatLayout.storage_verifier.
  private def storage_verifier
    ChatLayout.storage_verifier
  end

  private def find_authorized_blob(token : String, user : User) : ActiveStorage::Blob?
    blob_id = storage_verifier.verified_any(token, purpose: "blob_id")
      .try(&.as_i?)
    return nil unless blob_id
    blob = ActiveStorage::Blob.find?(blob_id.to_i64)
    return nil unless blob
    authorized_blob?(blob, user) ? blob : nil
  end

  # authorizedBlob (storage.js): User/Account attachments are public; Message/RichText —
  # membership in the message's room; no attachments — the owner from metadata.campfire_upload_user_id.
  private def authorized_blob?(blob : ActiveStorage::Blob, user : User) : Bool
    conn = ActiveRecord::Base.connection
    attachments = conn.query_all(
      "SELECT record_type, record_id FROM active_storage_attachments WHERE blob_id = ?",
      args: [blob.id!], as: {String, Int64})
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
            message_id, user.id!, as: Int64).nil?
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
end
