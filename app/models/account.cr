require "./application_record"

class Account < ApplicationRecord
  has_json :settings, restrict_room_creation_to_administrators: false

  # The reference's has_one_attached :logo: the attach/variant proxy and
  # the logo= setter for update!(account_params) uploads (has_one_attached)
  # + the preloading association readers (preloadable_attachment — its
  # logo_blob keeps the app's ActiveStorageBlob type).
  has_one_attached :logo
  preloadable_attachment :logo

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
