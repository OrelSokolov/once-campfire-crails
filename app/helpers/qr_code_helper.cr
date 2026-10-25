# QrCodeHelper: the zoomable QR-code link (port of the Rails oracle
# qr_code_helper.rb — inner markup comes from the caller's block).
# Deviation: base64url without padding (express routes.js contract — the QR
# controller decodes unpadded tokens; the oracle's urlsafe_encode64 pads).
module QrCodeHelper
  include ActionController::Helper

  def link_to_zoom_qr_code(url : String, &) : ERB::SafeString
    id = Base64.urlsafe_encode(url, padding: false)
    path = "/qr_code/#{id}"

    link_to path, class: "btn", data: {
      "lightbox_target"   => "image",
      "action"            => "lightbox#open",
      "lightbox_url_value" => path,
    } do
      yield
    end
  end
end
