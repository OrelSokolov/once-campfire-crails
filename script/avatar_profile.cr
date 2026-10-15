# Микробенчмарк компонентов пути GET /users/:token/avatar (не компилируется в bin/app):
#   DATABASE_URL=sqlite3:///tmp/avatar-profile/db/production.sqlite3 \
#   SECRET_KEY_BASE=... CAMPFIRE_STORAGE_ROOT=/tmp/avatar-profile/files \
#   crystal run --release script/avatar_profile.cr
require "../src/app_boot_models"
require "active_support_cr/message_verifier"

SECRET = ENV.fetch("SECRET_KEY_BASE")
TOKEN  = ENV.fetch("AVATAR_TOKEN")
USER_ID = 149_087_659_i64 # labels: avatar_tokens.jason

# Тот же вывод ключа, что railties Application#message_verifier.
def verifier(digest : OpenSSL::Algorithm = :sha1) : ActiveSupport::MessageVerifier
  key = OpenSSL::PKCS5.pbkdf2_hmac(SECRET, "active_record/signed_id", 1000,
    digest, key_size: 64)
  ActiveSupport::MessageVerifier.new(key, url_safe: true, digest: :sha1)
end

v_sha1 = verifier
v_sha256 = verifier(:sha256)

def bench(label, n)
  t0 = Time.instant
  n.times { yield }
  dt = Time.instant - t0
  printf("%-28s %8.1f µs/op  (total %6.1f ms)\n", label, dt.total_microseconds / n, dt.total_milliseconds)
end

N = 20_000

# 1. Проверка подписи: sha256-попытка (fail) + sha1-попытка (ok) — как в контроллере
bench("verify sha256(fail)+sha1(ok)", N) do
  v_sha256.verified_any(TOKEN, purpose: "user/avatar")
  v_sha1.verified_any(TOKEN, purpose: "user/avatar")
end

# 2. User.find?
user = nil
bench("User.find?", N) do
  user = User.find?(USER_ID)
end

# 3. avatar_blob: attachment + blob
bench("avatar_blob (2 queries)", N) do
  user.not_nil!.avatar_blob
end

# 4. Файловые операции send_file
key = user.not_nil!.avatar_blob.not_nil!.key.not_nil!
path = File.join(ENV.fetch("CAMPFIRE_STORAGE_ROOT"), key[0, 2], key[2, 2], key)
bench("File.exists? + open + read", N) do
  if File.exists?(path)
    File.open(path) { |f| IO.copy(f, IO::Memory.new) }
  end
end

# 5. Всё вместе (контроллер без HTTP)
bench("full controller work", N) do
  uid = v_sha256.verified_any(TOKEN, purpose: "user/avatar")
  uid = v_sha1.verified_any(TOKEN, purpose: "user/avatar") if uid.nil?
  u = uid.try(&.as_i?).try { |i| User.find?(i) }
  if (b = u.try(&.avatar_blob))
    k = b.key.not_nil!
    p = File.join(ENV.fetch("CAMPFIRE_STORAGE_ROOT"), k[0, 2], k[2, 2], k)
    File.open(p) { |f| IO.copy(f, IO::Memory.new) } if File.exists?(p)
  end
end
