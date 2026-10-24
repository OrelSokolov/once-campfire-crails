require "./application_record"

class Account < ApplicationRecord
  def restrict_room_creation_to_administrators? : Bool
    settings.try(&.["restrict_room_creation_to_administrators"]?.try(&.as_bool?)) == true
  end

  def restrict_room_creation_to_administrators=(value : Bool) : Nil
    # dup: as_h returns a reference into the JSON::Any hash — mutating it in
    # place would break dirty tracking (the snapshot would see the same value).
    base = settings.try(&.as_h.dup) || {} of String => JSON::Any
    base["restrict_room_creation_to_administrators"] = JSON::Any.new(value)
    self.settings = JSON::Any.new(base)
  end

  # The reference's has_one_attached :logo, looked up manually.
  def logo_attachment : ActiveStorageAttachment?
    ActiveStorageAttachment
      .where("record_type = ? AND record_id = ? AND name = ?", "Account", id.not_nil!, "logo")
      .take
  end

  def logo_blob : ActiveStorageBlob?
    logo_attachment.try do |attachment|
      ActiveStorageBlob.find(attachment.blob_id.not_nil!)
    end
  end

  # The reference's attachable.variant :large/:small: resize_to_limit 512/192, png.
  # Returns nil when there's no attachment, the type isn't variable, or vips fails —
  # the controller then serves the stock icon.
  LOGO_VARIANT_SIZES = {"large" => [512, 512], "small" => [192, 192]}

  def logo_variant(size : String = "large") : ActiveStorage::Variant?
    attachment = logo_attachment
    return nil unless attachment
    blob = ActiveStorage::Blob.find?(attachment.blob_id.not_nil!)
    return nil unless blob && blob.variable?
    dims = LOGO_VARIANT_SIZES[size]? || LOGO_VARIANT_SIZES["large"]
    blob.variant(resize_to_limit: dims, format: "png").processed
  rescue ex : Exception
    nil
  end
end
