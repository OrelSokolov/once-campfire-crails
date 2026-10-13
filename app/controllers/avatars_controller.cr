# GET /users/:token/avatar — аватар по Rails signed_id токену
# (контракт: 200, image/*, байты валидны ffprobe; токен из labels вида
# eyJfcmFpbHMiOnsiZGF0YSI6MTQ5MDg3NjU5LCJwdXIiOiJ1c2VyL2F2YXRhciJ9fQ--<hmac>).
#
# Ключ подписи: PBKDF2-SHA256(secret, "active_record/signed_id", 1000, 64),
# HMAC-SHA256 (см. campfire-express/src/rails.js: key()/verifyId).
class AvatarsController < ApplicationController
  skip_before_action :require_authentication # аватары публично линкуются

  def show
    user_id = verify_signed_id(params["token"].to_s, purpose: "user/avatar")
    return render(plain: "invalid avatar token", status: 404) if user_id.nil?

    user = User.find?(user_id)
    blob = user.try(&.avatar_blob)
    return render(plain: "no avatar", status: 404) if blob.nil?

    key = blob.not_nil!.key.not_nil!
    path = File.join(storage_root, key[0, 2], key[2, 2], key)
    return render(plain: "avatar file missing", status: 404) unless File.exists?(path)

    response.headers["Cache-Control"] = "public, max-age=1800"
    send_file(path, disposition: "inline", content_type: blob.not_nil!.content_type.to_s)
  end

  private def verify_signed_id(token : String, purpose : String) : Int64?
    secret = ENV["SECRET_KEY_BASE"]? ||
             raise RuntimeError.new("SECRET_KEY_BASE is not configured")
    key = ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(secret, iterations: 1000, digest: :sha256))
      .generate_key("active_record/signed_id")
    # express/verifier: digest sha256, fallback sha1
    verifier = ActiveSupport::MessageVerifier.new(key, url_safe: true, digest: :sha256)
    value = verifier.verified_any(token, purpose: purpose)
    if value.nil?
      verifier = ActiveSupport::MessageVerifier.new(key, url_safe: true, digest: :sha1)
      value = verifier.verified_any(token, purpose: purpose)
    end
    if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
      return raw.to_i64
    end
    nil
  end

  # Storage root: harness монтирует сид в /rails/storage/files; локально —
  # настраивается переменной.
  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end
end
