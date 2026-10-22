# GET /qr_code/:id — QR-код ссылки (референс: campfire-express
# src/public.js /qr_code/:id): :id — base64url значения (<=4096 UTF-8
# символов), отдаётся PNG через rqrcode_cr (порт rqrcode 2.2.0).
class QrCodeController < ApplicationController
  skip_before_action :require_authentication

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
    render(plain: png.to_s, content_type: "image/png")
  end
end
