require "../application_record"

class Message
  module Attachment
    # Uploaded file from the multipart upload: the client posts the file directly with the message.
    record UploadedFile, filename : String, content_type : String, bytes : Bytes

    def self.store(conn, message : Message, upload : UploadedFile, now : Time) : Nil
      message_id = message.id.not_nil!
      filename = File.basename(upload.filename.presence || "file")
      content_type = upload.content_type.presence || "application/octet-stream"
      blob = ActiveStorage::Blob.create_and_upload!(
        io: String.new(upload.bytes), filename: filename, content_type: content_type)
      # Shard's analyze! fills the image width/height metadata (Rails format) used by
      # preview_dimensions; non-images analyze to nothing. Runs synchronously in the transaction.
      blob.analyze!
      conn.exec(
        "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('attachment', 'Message', $1, $2, $3)",
        message_id, blob.id.not_nil!, now)
      message.touch
    end
  end
end
