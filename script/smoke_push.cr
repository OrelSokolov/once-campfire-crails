# Smoke для Web Push (app/jobs/web_push.cr):
#   1. HKDF-SHA256 по вектору RFC 5869 (Test Case 1)
#   2. ECDH P-256: совпадение общих секретов двух сторон
#   3. (опционально, при PUSH_ENDPOINT) доставка на mock-endpoint —
#      public_only=false: локальный тестовый сервер, реальная доставка
#      джобы использует публичные адреса только.
#
# Запуск с mock: см. задачи rake /tmp/push-test. Без env-переменных
# проверяются только чистые функции.
require "../src/app_boot_models"
require "../app/jobs/web_push"

failures = 0

# ————— 1. HKDF RFC 5869 Test Case 1 —————
ikm = Bytes.new(22, 0x0b)
salt = Bytes[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
info = Bytes[0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9]
expected = "3cb25f25faacd57a90434f64d0362f2a" \
           "2d2d0a90cf1a5a4c5db02d56ecc4c5bf" \
           "34007208d5b887185865"
okm = Campfire::WebPush.hkdf_sha256(ikm, salt, info, 42).hexstring
if okm == expected
  puts "HKDF RFC 5869: OK"
else
  puts "HKDF RFC 5869: FAIL got #{okm}"
  failures += 1
end

# ————— 2. ECDH P-256 roundtrip —————
alice = Campfire::WebPush::EcKey.generate
bob = Campfire::WebPush::EcKey.generate
begin
  s1 = alice.shared_secret(bob.public_point)
  s2 = bob.shared_secret(alice.public_point)
  if s1 == s2 && s1.size == 32
    puts "ECDH P-256: OK (#{s1.hexstring[0, 16]}…)"
  else
    puts "ECDH P-256: FAIL #{s1.hexstring} vs #{s2.hexstring}"
    failures += 1
  end
ensure
  alice.free
  bob.free
end

# ————— 3. ES256 подпись:.der→raw r||s по 64 байта —————
# DER-подпись из OpenSSL всегда валидна, проверяем конвертер на
# синтетическом примере r=1, s=2 → 32 нуля + 0x01 + 31 ноль + 0x02
der = Bytes[0x30, 6, 0x02, 1, 1, 0x02, 1, 2]
raw = Campfire::WebPush.ecdsa_der_to_raw(der)
expected_raw = Bytes.new(64)
expected_raw[31] = 1
expected_raw[63] = 2
if raw == expected_raw
  puts "ECDSA DER→raw: OK"
else
  puts "ECDSA DER→raw: FAIL #{raw.hexstring}"
  failures += 1
end

# ————— 4. Доставка на mock-endpoint (опционально) —————
if (endpoint = ENV["PUSH_ENDPOINT"]?)
  status = Campfire::WebPush.deliver(
    endpoint,
    ENV["PUSH_P256DH"].not_nil!,
    ENV["PUSH_AUTH"].not_nil!,
    ENV["PUSH_PAYLOAD"]? || %({"title":"HQ","options":{"body":"hello","data":{"path":"/rooms/1","badge":2}}}),
    ENV["VAPID_PUBLIC_KEY"].not_nil!,
    ENV["VAPID_PRIVATE_KEY"].not_nil!,
    "mailto:smoke@example.com",
    public_only: false)
  puts "deliver: status=#{status.inspect}"
end

if failures > 0
  puts "#{failures} FAILURES"
  exit 1
end
puts "all vector checks passed"
