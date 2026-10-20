# GET /rails/active_storage/blobs/redirect/:token/:filename и
# .../representations/redirect/:token/:variation/:filename — отдача
# вложений сообщений (порт storage.js registerStorage): подпись blob_id
# верификатором с salt "ActiveStorage" (purpose blob_id/variation),
# авторизация как authorizedBlob (membership комнаты сообщения),
# servingAttributes (inline для картинок, attachment для остального).
# Representation переменчивого типа (картинка) — ленивый вариант через
# Variation шарда (image_processing, vips) с кешем variants/<key>/…;
# ошибка обработки/чужой тип — отдаётся оригинальный файл.
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

  # Путь файла на Disk-сервисе (fan-аут гема — DiskService#path_for шарда).
  private def disk_path(key : String) : String
    service = ActiveStorage.service
    raise "active storage service is not disk-backed" unless service.is_a?(ActiveStorage::DiskService)
    service.path_for(key)
  end

  # Ленивая обработка варианта (RepresentationsController#edit гема):
  # transformations из подписанного variation-токена → Variation шарда
  # → transform через image_processing; результат кешируется на диске
  # под variants/<blob.key>/<variation.key> (как Variant#processed).
  # Видео — не variable: это превью (AttachmentPresentation video_
  # poster_url) — кадр извлекается ffmpeg (ActiveStorage::Preview::
  # VideoPreviewer: -vf scale=640:-1 -frames:v 1, jpg) и прогоняется
  # через ту же Variation (webp). nil — обработка упала: оригинал.
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
    # vips/mini_magick не осилил файл — оригинал (как до подключения
    # шарда).
    nil
  end

  # VideoPreviewer#draw референса: первый кадр, 640 по ширине, image2.
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

  # Расширение источника для transform (фолбок png, как в Variation).
  private def mimedefault_ext(blob : ActiveStorageBlob) : String
    ext = File.extname(blob.filename.to_s).lchop('.')
    ext.empty? ? "png" : ext
  end

  # Верификатор с salt "ActiveStorage" (sha1, strict_b64 с паддингом —
  # общий с ChatLayout.storage_verifier).
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
end