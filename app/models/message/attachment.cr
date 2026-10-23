require "../application_record"

# Message::Attachment (message/attachment.rb): сохранение файла
# вложения сообщения — blob + active_storage_attachments + touch
# (storage.js storeUpload + attachMessage у express-референса).
class Message
  module Attachment
    # Загруженный файл (multipart от file_uploader.js): клиент шлёт файл
    # прямо в POST /rooms/:id/messages, без ActiveStorage direct uploads.
    record UploadedFile, filename : String, content_type : String, bytes : Bytes

    def self.store(conn, message : Message, upload : UploadedFile, now : Time) : Nil
      message_id = message.id.not_nil!
      filename = File.basename(upload.filename.presence || "file")
      content_type = upload.content_type.presence || "application/octet-stream"
      blob = ActiveStorage::Blob.create_and_upload!(
        io: String.new(upload.bytes), filename: filename, content_type: content_type)
      # Blob#analyze! шарда (порт Analyzable 8.1.4): width/height картинки
      # в metadata (`{"width":W,"height":H,"analyzed":true}` — формат
      # Rails), откуда их берёт preview_dimensions рендера; не-картинки —
      # NullAnalyzer (analyzed:true). Анализ — чтение заголовка через
      # vips, синхронно внутри production-транзакции.
      blob.analyze!
      conn.exec(
        "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('attachment', 'Message', $1, $2, $3)",
        message_id, blob.id.not_nil!, now)
      message.touch
    end
  end
end
