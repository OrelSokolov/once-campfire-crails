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
  # from the signed variation token → the shard's Variation → image_processing transform,
  # cached on disk under variants/<blob.key>/<variation.key>. Video is not variable: the
  # preview frame is extracted with ffmpeg and run through the same Variation. nil means
  # processing failed → the original file.
  private def representation_variant(blob : ActiveStorageBlob,
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
    variation = ActiveStorage::Variation.new(transformations)
    variant_key = "variants/#{blob.key}/#{variation.key}"
    service = ActiveStorage.service
    return nil unless service.is_a?(ActiveStorage::DiskService)

    input_key, source_ext =
      if blob.content_type.to_s.starts_with?("video/")
        frame_key = "previews/#{blob.key}"
        unless service.exist?(frame_key)
          frame = extract_video_frame(service.path_for(blob.key.to_s))
          return nil unless frame
          service.upload(frame_key, frame, content_type: "image/jpeg")
        end
        {frame_key, "jpg"}
      else
        return nil unless ActiveStorage::Blob::VARIABLE_CONTENT_TYPES.includes?(
          blob.content_type.to_s)
        {blob.key.to_s, mimedefault_ext(blob)}
      end

    unless service.exist?(variant_key)
      source = service.download(input_key)
      bytes = variation.transform(source, source_ext)
      service.upload(variant_key, bytes, content_type: variation.content_type)
    end
    {service.path_for(variant_key), variation.content_type}
  rescue ex : Exception
    # vips/mini_magick could not handle the file — the original (as before the shard).
    nil
  end

  # The reference's VideoPreviewer#draw: first frame, 640 wide, image2.
  private def extract_video_frame(source_path : String) : String?
    frame_path = File.join(Dir.tempdir, "as_preview_#{Random::Secure.hex(8)}.jpg")
    status = Process.run("ffmpeg", {"-y", "-i", source_path, "-vf", "scale=640:-1",
      "-frames:v", "1", "-f", "image2", frame_path},
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    return nil unless status.success? && File.exists?(frame_path)
    bytes = File.read(frame_path)
    File.delete(frame_path)
    bytes
  rescue ex : Exception
    nil
  end

  # Source extension for transform (png fallback, like Variation).
  private def mimedefault_ext(blob : ActiveStorageBlob) : String
    ext = File.extname(blob.filename.to_s).lchop('.')
    ext.empty? ? "png" : ext
  end

  # Verifier with salt "ActiveStorage", shared with ChatLayout.storage_verifier.
  private def storage_verifier
    ChatLayout.storage_verifier
  end

  private def find_authorized_blob(token : String, user : User) : ActiveStorageBlob?
    blob_id = storage_verifier.verified_any(token, purpose: "blob_id")
      .try(&.as_i?)
    return nil unless blob_id
    blob = ActiveStorageBlob.find?(blob_id.to_i64)
    return nil unless blob
    authorized_blob?(blob, user) ? blob : nil
  end

  # authorizedBlob (storage.js): User/Account attachments are public; Message/RichText —
  # membership in the message's room; no attachments — the owner from metadata.campfire_upload_user_id.
  private def authorized_blob?(blob : ActiveStorageBlob, user : User) : Bool
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
