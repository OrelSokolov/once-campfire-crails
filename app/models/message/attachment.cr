require "../application_record"

class Message
  module Attachment
    # Oracle Message::Attachment (activestorage 8.2.alpha): the thumbnail
    # limits and the eager preview processing run when the message is
    # posted. :thumb — a vips variant of the image; :poster — an ffmpeg
    # frame of the video converted to webp.

    THUMBNAIL_MAX_WIDTH = 1200
    THUMBNAIL_MAX_HEIGHT = 800

    # Decoding a picture, or a video's frame, costs in proportion to its pixels, however small the file. The largest
    # phone photos have 200 million.
    THUMBNAIL_MAX_PIXELS = 250_000_000

    # Uploaded file from the multipart upload: the client posts the file directly with the message.
    record UploadedFile, filename : String, content_type : String, bytes : Bytes

    def self.store(conn, message : Message, upload : UploadedFile, now : Time) : ActiveStorage::Blob
      message_id = message.id!
      filename = File.basename(upload.filename.presence || "file")
      content_type = upload.content_type.presence || "application/octet-stream"
      blob = ActiveStorage::Blob.create_and_upload!(
        io: String.new(upload.bytes), filename: filename, content_type: content_type)
      # Shard's analyze! fills the image/video width/height metadata (Rails
      # format) used by preview_dimensions and the pixels guard; other types
      # analyze to {"analyzed":true} only. Runs synchronously in the transaction.
      blob.analyze!
      conn.exec(
        "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('attachment', 'Message', $1, $2, $3)",
        message_id, blob.id!, now)
      message.touch
      blob
    end

    # create_with_attachment!'s process_attachment: MessageCreator calls it
    # after the create transaction commits, before the broadcast renders
    # the presentation.
    def self.process_attachment(blob : ActiveStorage::Blob) : Nil
      ensure_attachment_analyzed(blob)
      process_attachment_thumbnail(blob)
    end

    # The concern's named variants (attachable.variant :thumb/:poster). The
    # transformations are byte-equal to what ChatLayout.representation_url
    # signs and the representations route decodes; :thumb's format is
    # defaulted by Blob#variant (web image → the source extension, else png).
    def self.thumb_transformations : Hash(String, ActiveStorage::Variation::Value)
      {"resize_to_limit" => [THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT]} of String => ActiveStorage::Variation::Value
    end

    def self.poster_transformations : Hash(String, ActiveStorage::Variation::Value)
      {"format" => "webp", "resize_to_limit" => [THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT]} of String => ActiveStorage::Variation::Value
    end

    def self.ensure_attachment_analyzed(blob : ActiveStorage::Blob) : Nil
      blob.analyze unless blob.analyzed?
    end

    # A file that ffmpeg or libvips can't decode is still the message: post it without a preview.
    def self.process_attachment_thumbnail(blob : ActiveStorage::Blob) : Nil
      return if too_many_pixels_to_preview?(blob)

      if blob.video?
        blob.preview(poster_transformations).processed
      elsif blob.representable?
        blob.representation(thumb_transformations).processed
      end
    rescue ex : ActiveStorage::PreviewError | ::Vips::Error
      CRails.logger.warn { "Posted #{blob.filename} without a preview: #{ex.class}: #{ex.message.to_s.lines.first?.try(&.chomp)}" }
    end

    # Without a size, the analyzer couldn't read the file's header, and the previewer wouldn't either.
    def self.too_many_pixels_to_preview?(blob : ActiveStorage::Blob) : Bool
      if blob.image? || blob.video?
        meta = blob.metadata_hash
        width = pixel_size(meta["width"]?)
        height = pixel_size(meta["height"]?)
        width.nil? || height.nil? || width * height > THUMBNAIL_MAX_PIXELS
      else
        false
      end
    end

    private def self.pixel_size(value : ActiveStorage::Analyzer::Value?) : Float64?
      case v = value
      when Int64   then v.to_f64
      when Float64 then v
      else              nil
      end
    end
  end
end
