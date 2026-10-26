# GET /qr_code/:id — QR code of a base64url value (<=4096 UTF-8 chars), served as PNG
# via rqrcode_cr.
class QrCodeController < ApplicationController
  allow_unauthenticated_access

  def show
    encoded = params["id"].to_s
    padded = encoded.tr("-_", "+/")
    padded += "=" * ((4 - padded.size % 4) % 4)
    value = begin
      bytes = Base64.decode(padded)
      string = String.new(bytes)
      string.valid_encoding? && string.size <= 4096 ? string : nil
    rescue ArgumentError | Base64::Error
      nil
    end
    return render(plain: "not found", status: 404) unless value

    png = RQRCode::QRCode.new(value.not_nil!).as_png(size: 120)
    expires_in 1.year, public: true
    render(plain: png.to_s, content_type: "image/png")
  end
end
