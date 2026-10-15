# Smoke: печатает signed avatar-токен (purpose user/avatar) для пользователя.
require "../src/app_boot_models"

CRails.application.initialize!
uid = ARGV[0]? || "127326141"
verifier = CRails.application.message_verifier("active_record/signed_id",
  url_safe: true)
puts verifier.generate(uid.to_i64, purpose: "user/avatar")
