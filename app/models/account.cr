require "./application_record"

class Account < ApplicationRecord
  # Rails reads the switch through has_json :settings (typed accessor);
  # until that port (phase 4) update!(account_params) stores the form's
  # strings as-is, so both shapes are accepted here.
  def restrict_room_creation_to_administrators? : Bool
    case raw = settings.try(&.["restrict_room_creation_to_administrators"]?).try(&.raw)
    when Bool   then raw
    when String then raw == "true"
    else             false
    end
  end

  # The reference's has_one_attached :logo, looked up manually.
  def logo_attachment : ActiveStorageAttachment?
    ActiveStorageAttachment
      .where("record_type = ? AND record_id = ? AND name = ?", "Account", id.not_nil!, "logo")
      .take
  end

  def logo_blob : ActiveStorageBlob?
    logo_attachment.try do |attachment|
      ActiveStorageBlob.find(attachment.blob_id!)
    end
  end

  # The reference's attachable.variant :large/:small: resize_to_limit 512/192, png.
  # Returns nil when there's no attachment, the type isn't variable, or vips fails —
  # the controller then serves the stock icon.
  LOGO_VARIANT_SIZES = {"large" => [512, 512], "small" => [192, 192]}

  def logo_variant(size : String = "large") : ActiveStorage::Variant?
    attachment = logo_attachment
    return nil unless attachment
    blob = ActiveStorage::Blob.find?(attachment.blob_id!)
    return nil unless blob && blob.variable?
    dims = LOGO_VARIANT_SIZES[size]? || LOGO_VARIANT_SIZES["large"]
    blob.variant(resize_to_limit: dims, format: "png").processed
  rescue ex : Exception
    nil
  end
end
