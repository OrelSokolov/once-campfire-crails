require "http"
require "json"
require "openssl"
require "socket"

# Web Push доставка — порт push-ветки perform из src/jobs.js
# (once-campfire-express) + vapid-helper/web-push-lib npm:
#   - шифрование payload aes128gcm (RFC 8188/8291): ECDH P-256 +
#     HKDF-SHA256 + AES-128-GCM, запись rs=4096, одна запись,
#     паддинг — только разделитель 0x02;
#   - VAPID (RFC 8292): JWT ES256 {aud, exp (+12ч), sub},
#     Authorization: `vapid t=<jwt>, k=<public>`, TTL 2419200,
#     Content-Type application/octet-stream;
#   - SSRF-фильтр resolvePublic (opengraph.js publicAddress):
#     endpoint резолвится заранее, приватные/небраузерные адреса
#     запрещены, соединение — только с разрешённым IP (DNS-pinning,
#     SNI/верификация по имени хоста), только https.
#
# Криптография — libcrypto (OpenSSL 3) напрямую: stdlib не
# экспортирует ECDH/ES256-подпись/GCM-тег.
module Campfire
  module WebPush
    class Error < Exception
    end

    # ————— Публичное API —————

    # Шифрует payload (RFC 8291) ключами подписки.
    # p256dh/auth — base64url (с паддингом или без) от клиента.
    def self.encrypt(p256dh : String, auth : String, payload : String) : Bytes
      ua_public = decode_key(p256dh) || raise Error.new("invalid p256dh key")
      auth_secret = decode_key(auth) || raise Error.new("invalid auth key")
      raise Error.new("invalid p256dh key length") unless ua_public.size == 65 && ua_public[0] == 0x04
      raise Error.new("invalid auth key length") unless auth_secret.size == 16

      ephemeral = EcKey.generate
      begin
        as_public = ephemeral.public_point
        ecdh_secret = ephemeral.shared_secret(ua_public)

        # RFC 8291 §3.2: ikm=ecdh, salt=auth_secret,
        # info="WebPush: info\0" + ua_public || as_public
        prk_key = hkdf_sha256(ecdh_secret, auth_secret,
          "WebPush: info\0".to_slice + ua_public + as_public, 32)
        salt = Random::Secure.random_bytes(16)
        cek = hkdf_sha256(prk_key, salt, "Content-Encoding: aes128gcm\0".to_slice, 16)
        nonce = hkdf_sha256(prk_key, salt, "Content-Encoding: nonce\0".to_slice, 12)

        # Одна запись rs=4096: plaintext + разделитель 0x02 без паддинга
        ciphertext = aes128gcm_encrypt(cek, nonce, payload.to_slice + Bytes[0x02])

        # RFC 8188 §2: salt(16) + rs(4 BE) + idlen(1) + keyid(65) + ciphertext
        body = Bytes.new(16 + 4 + 1 + 65 + ciphertext.size)
        body.copy_from(salt)
        body[16], body[17], body[18], body[19] = 0x00.to_u8, 0x00.to_u8, 0x10.to_u8, 0x00.to_u8 # rs=4096 BE
        body[20] = 65.to_u8
        (body + 21).copy_from(as_public)
        (body + 21 + 65).copy_from(ciphertext)
        body
      ensure
        ephemeral.free
      end
    end

    # Authorization-заголовок VAPID (web-push npm v3, aes128gcm-ветка):
    # `vapid t=<jwt ES256>, k=<public_key>`; audience = origin endpoint'а.
    def self.vapid_authorization(audience : String, subject : String,
                                 public_key : String, private_key : String) : String
      header = Base64.urlsafe_encode(%({"typ":"JWT","alg":"ES256"}), padding: false)
      exp = Time.utc.to_unix + 12 * 60 * 60 # DEFAULT_EXPIRATION_SECONDS
      claims = Base64.urlsafe_encode(
        %({"aud":#{audience.to_json},"exp":#{exp},"sub":#{subject.to_json}}),
        padding: false)
      signing_input = "#{header}.#{claims}"

      scalar = decode_key(private_key) || raise Error.new("invalid VAPID private key")
      key = EcKey.from_private_scalar(scalar)
      begin
        der = key.es256_sign(signing_input.to_slice)
        raw = ecdsa_der_to_raw(der)
        "vapid t=#{signing_input}.#{Base64.urlsafe_encode(raw, padding: false)}, k=#{public_key.rstrip('=')}"
      ensure
        key.free
      end
    end

    # POST зашифрованного payload на endpoint подписки. Возвращает HTTP-статус;
    # nil — подписка пропускается (не-https endpoint или приватный адрес,
    # как resolvePublic-continue в jobs.js). Сетевые ошибки — исключение
    # (джоба уйдёт в retry). public_only=false — только для локальных тестов.
    def self.deliver(endpoint : String, p256dh : String, auth : String,
                     payload : String, vapid_public : String, vapid_private : String,
                     vapid_subject : String = "mailto:campfire@example.com",
                     *, public_only : Bool = true) : Int32?
      url = URI.parse(endpoint)
      host = url.host.to_s.strip("[]")
      return nil unless url.scheme == "https"
      return nil if url.user || url.password
      return nil if host.empty?

      address = resolve_public(url, public_only) || (return nil)
      encrypted = encrypt(p256dh, auth, payload)
      audience = url.port ? "#{url.scheme}://#{host}:#{url.port}" : "#{url.scheme}://#{host}"
      authorization = vapid_authorization(audience, vapid_subject, vapid_public, vapid_private)

      headers = HTTP::Headers{
        "TTL"               => "2419200",
        "Content-Encoding"  => "aes128gcm",
        "Content-Type"      => "application/octet-stream",
        "Authorization"     => authorization,
      }

      socket = TCPSocket.new(address, url.port || 443, connect_timeout: 7.seconds)
      begin
        tls = OpenSSL::SSL::Socket::Client.new(socket, hostname: host)
        tls.read_timeout = 7.seconds
        tls.write_timeout = 7.seconds
        client = HTTP::Client.new(tls)
        client.post(url.request_target.not_nil!, headers: headers, body: encrypted).status_code
      ensure
        socket.close rescue nil
      end
    end

    # ————— HKDF (RFC 5869, SHA-256) —————

    # Base64url без паддинга (или с ним) ключей подписки/VAPID → байты.
    private def self.decode_key(text : String) : Bytes?
      sanitized = text.tr("-_", "+/").gsub(/\s+/, "")
      sanitized += "=" * ((4 - sanitized.size % 4) % 4)
      Base64.decode(sanitized)
    rescue
      nil
    end

    def self.hkdf_sha256(ikm : Bytes, salt : Bytes, info : Bytes, length : Int32) : Bytes
      prk = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, salt, ikm)
      block = Bytes.new(0)
      okm = Bytes.new(length)
      filled = 0
      counter = 1
      while filled < length
        input = block + info + Bytes[counter.to_u8!]
        block = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, prk, input)
        take = Math.min(32, length - filled)
        (okm + filled).copy_from(block[0, take])
        filled += take
        counter += 1
      end
      okm
    end

    # ————— AES-128-GCM (EVP напрямую: stdlib Cipher не отдаёт тег) —————

    EVP_CTRL_GCM_SET_IVLEN = 0x9
    EVP_CTRL_GCM_GET_TAG   = 0x10

    def self.aes128gcm_encrypt(key : Bytes, iv : Bytes, plaintext : Bytes) : Bytes
      ctx = LibCrypto.evp_cipher_ctx_new
      begin
          raise Error.new("EVP_EncryptInit failed") unless LibWebPushCrypto.evp_encrypt_init_ex(
            ctx, LibWebPushCrypto.evp_aes_128_gcm, nil, nil, nil) == 1
          raise Error.new("set ivlen failed") unless LibWebPushCrypto.evp_cipher_ctx_ctrl(
            ctx, EVP_CTRL_GCM_SET_IVLEN, iv.size, nil) == 1
          raise Error.new("EVP_EncryptInit failed") unless LibWebPushCrypto.evp_encrypt_init_ex(
            ctx, nil, nil, key, iv) == 1
          buf = Bytes.new(plaintext.size + 16)
          written = 0
          outl = 0
          if plaintext.size > 0
            raise Error.new("EVP_EncryptUpdate failed") unless LibWebPushCrypto.evp_encrypt_update(
              ctx, buf, pointerof(outl), plaintext, plaintext.size) == 1
            written = outl
          end
          raise Error.new("EVP_EncryptFinal failed") unless LibWebPushCrypto.evp_encrypt_final_ex(
            ctx, buf + written, pointerof(outl)) == 1
          written += outl
          tag = Bytes.new(16)
          raise Error.new("get tag failed") unless LibWebPushCrypto.evp_cipher_ctx_ctrl(
            ctx, EVP_CTRL_GCM_GET_TAG, 16, tag) == 1
          buf[0, written] + tag
      ensure
        LibCrypto.evp_cipher_ctx_free(ctx)
      end
    end

    # ————— ECDSA DER → JOSE raw r||s (RFC 7518 §3.4) —————

    def self.ecdsa_der_to_raw(der : Bytes) : Bytes
      raise Error.new("bad ECDSA signature") unless der.size >= 8 && der[0] == 0x30
      pos = 2 # короткая форма длины: подпись всегда < 128 байт
      raise Error.new("bad ECDSA signature") unless der[pos] == 0x02
      r_len = der[pos + 1].to_i32
      r = der[pos + 2, r_len]
      pos = pos + 2 + r_len
      raise Error.new("bad ECDSA signature") unless der[pos]? == 0x02
      s_len = der[pos + 1].to_i32
      s = der[pos + 2, s_len]? || raise Error.new("bad ECDSA signature")

      int_bytes = ->(b : Bytes) do
        first = b.index { |byte| byte != 0 } || b.size # ведущие нули DER
        src = b[first..]
        take = Math.min(src.size, 32)
        src = src[src.size - take, take]
        Bytes.new(32).tap { |pad| (pad + (32 - take)).copy_from(src) }
      end
      int_bytes.call(r) + int_bytes.call(s)
    end

    # ————— SSRF-фильтр (порт publicAddress из opengraph.js) —————

    # Все адреса хоста должны быть публичными; берём первый.
    def self.resolve_public(url : URI, public_only : Bool = true) : String?
      host = url.host.to_s.strip("[]")
      addresses = Socket::Addrinfo.tcp(host, url.port || 443).map(&.ip_address.address)
      addresses.uniq!
      return nil if addresses.empty?
      return addresses.first if !public_only
      return nil unless addresses.all? { |a| public_address?(a) }
      addresses.first
    end

    def self.public_address?(address : String) : Bool
      if address.matches?(/\A(\d{1,3}\.){3}\d{1,3}\z/)
        octets = address.split('.').map(&.to_i32)
        a, b = octets[0], octets[1]
        return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                 (a == 169 && b == 254) ||
                 (a == 172 && b >= 16 && b <= 31) ||
                 (a == 192 && (b == 168 || b == 0)) ||
                 (a == 100 && b >= 64 && b <= 127) ||
                 (a == 198 && (b == 18 || b == 19)) ||
                 (a == 198 && b == 51) ||
                 (a == 203 && b == 0))
      end
      # IPv6: только global unicast (2xxx/3xxx), мапнутые/спец-диапазоны fail closed
      ip = address.downcase
      !ip.includes?('.') && ip.starts_with?("2", "3") &&
        !ip.starts_with?("2001:db8:", "2001:0:", "2002:", "2001:11", "fc", "fd")
    rescue Socket::Error | ArgumentError
      false
    end

    # ————— Обёртка EC P-256 над libcrypto —————

    NID_X9_62_PRIME256V1     = 415
    POINT_CONVERSION_UNCOMP  = 4

    class EcKey
      def initialize(@key : LibWebPushCrypto::EcKey)
        raise Error.new("EC_KEY_new failed") unless @key
      end

      def self.generate : EcKey
        key = LibWebPushCrypto.ec_key_new_by_curve_name(NID_X9_62_PRIME256V1)
        inst = new(key)
        raise Error.new("EC_KEY_generate_key failed") unless LibWebPushCrypto.ec_key_generate_key(key) == 1
        inst
      end

      def self.from_public_point(point : Bytes) : EcKey
        key = LibWebPushCrypto.ec_key_new_by_curve_name(NID_X9_62_PRIME256V1)
        inst = new(key)
        group = LibWebPushCrypto.ec_key_get0_group(key)
        ec_point = LibWebPushCrypto.ec_point_new(group)
        begin
          unless LibWebPushCrypto.ec_point_oct2point(group, ec_point,
               point, point.size, nil) == 1 &&
             LibWebPushCrypto.ec_key_set_public_key(key, ec_point) == 1
            LibWebPushCrypto.ec_point_free(ec_point)
            LibWebPushCrypto.ec_key_free(key)
            raise Error.new("invalid public point")
          end
        ensure
          LibWebPushCrypto.ec_point_free(ec_point)
        end
        inst
      end

      def self.from_private_scalar(scalar : Bytes) : EcKey
        key = LibWebPushCrypto.ec_key_new_by_curve_name(NID_X9_62_PRIME256V1)
        inst = new(key)
        begin
          bn = LibWebPushCrypto.bn_bin2bn(scalar, scalar.size, nil)
          raise Error.new("BN_bin2bn failed") unless bn
          unless LibWebPushCrypto.ec_key_set_private_key(key, bn) == 1
            LibWebPushCrypto.bn_free(bn)
            raise Error.new("set private key failed")
          end
          # Публичная точка нужна EVP-провайдеру для операций с ключом
          group = LibWebPushCrypto.ec_key_get0_group(key)
          pub = LibWebPushCrypto.ec_point_new(group)
          order = LibWebPushCrypto.bn_new
          begin
            unless LibWebPushCrypto.ec_group_get_order(group, order, nil) == 1 &&
                   LibWebPushCrypto.ec_point_mul(group, pub, bn, nil, nil, nil) == 1 &&
                   LibWebPushCrypto.ec_key_set_public_key(key, pub) == 1
              raise Error.new("derive public key failed")
            end
          ensure
            LibWebPushCrypto.bn_free(order)
            LibWebPushCrypto.ec_point_free(pub)
          end
        rescue e
          LibWebPushCrypto.ec_key_free(key)
          raise e
        end
        inst
      end

      # Несжатая точка (0x04 || X || Y), 65 байт.
      def public_point : Bytes
        group = LibWebPushCrypto.ec_key_get0_group(@key)
        point = LibWebPushCrypto.ec_key_get0_public_key(@key)
        raise Error.new("no public key") unless group && point
        len = LibWebPushCrypto.ec_point_point2oct(group, point,
          POINT_CONVERSION_UNCOMP, nil, 0, nil)
        raise Error.new("ec_point_point2oct failed") if len == 0
        buf = Bytes.new(len)
        len = LibWebPushCrypto.ec_point_point2oct(group, point,
          POINT_CONVERSION_UNCOMP, buf, buf.size, nil)
        raise Error.new("ec_point_point2oct failed") if len == 0
        buf
      end

      # ECDH: общий секрет с точкой пирa (65 байт uncompressed).
      def shared_secret(peer_point : Bytes) : Bytes
        peer = EcKey.from_public_point(peer_point)
        peer_pkey = LibWebPushCrypto.evp_pkey_new
        own_pkey = LibWebPushCrypto.evp_pkey_new
        secret = Bytes.new(0)
        ctx = nil
        begin
          # assign передаёт владение EVP_PKEY → освобождаемого нами EC_KEY
          # дублируем (иначе двойной EC_KEY_free)
          raise Error.new("EC_KEY_dup failed") unless (peer_dup = LibWebPushCrypto.ec_key_dup(peer.key_handle)) &&
            (own_dup = LibWebPushCrypto.ec_key_dup(@key))
          raise Error.new("assign peer key failed") unless LibWebPushCrypto.evp_pkey_assign(peer_pkey, 408, peer_dup) == 1
          raise Error.new("assign own key failed") unless LibWebPushCrypto.evp_pkey_assign(own_pkey, 408, own_dup) == 1
          # derive-контекст — от собственного приватного ключа
          ctx = LibWebPushCrypto.evp_pkey_ctx_new(own_pkey, nil)
          raise Error.new("derive_init failed") unless ctx &&
            LibWebPushCrypto.evp_pkey_derive_init(ctx) == 1
          raise Error.new("derive_set_peer failed") unless LibWebPushCrypto.evp_pkey_derive_set_peer(ctx, peer_pkey) == 1
          len = LibC::SizeT.new(0)
          raise Error.new("derive failed") unless LibWebPushCrypto.evp_pkey_derive(ctx, nil, pointerof(len)) == 1
          secret = Bytes.new(len.to_i32)
          raise Error.new("derive failed") unless LibWebPushCrypto.evp_pkey_derive(ctx, secret, pointerof(len)) == 1
          secret
        ensure
          LibWebPushCrypto.evp_pkey_ctx_free(ctx) if ctx
          LibWebPushCrypto.evp_pkey_free(peer_pkey) if peer_pkey
          LibWebPushCrypto.evp_pkey_free(own_pkey) if own_pkey
          peer.free
        end
      end

      # ES256 (ECDSA/SHA-256) — DER-подпись входа.
      def es256_sign(data : Bytes) : Bytes
        pkey = LibWebPushCrypto.evp_pkey_new
        md_ctx = LibCrypto.evp_md_ctx_new
        begin
          raise Error.new("EC_KEY_dup failed") unless (own_dup = LibWebPushCrypto.ec_key_dup(@key))
          raise Error.new("assign key failed") unless LibWebPushCrypto.evp_pkey_assign(pkey, 408, own_dup) == 1
          raise Error.new("DigestSignInit failed") unless md_ctx &&
            LibWebPushCrypto.evp_digest_sign_init(md_ctx, nil,
              LibCrypto.evp_sha256.as(LibWebPushCrypto::EvpMd), nil, pkey) == 1
          len = LibC::SizeT.new(0)
          raise Error.new("DigestSign failed") unless LibWebPushCrypto.evp_digest_sign(md_ctx, nil, pointerof(len), data, data.size) == 1
          sig = Bytes.new(len.to_i32)
          raise Error.new("DigestSign failed") unless LibWebPushCrypto.evp_digest_sign(md_ctx, sig, pointerof(len), data, data.size) == 1
          sig[0, len.to_i32]
        ensure
          LibCrypto.evp_md_ctx_free(md_ctx) if md_ctx
          LibWebPushCrypto.evp_pkey_free(pkey) if pkey
        end
      end

      # Сырой указатель EC_KEY (для ec_key_dup).
      def key_handle : LibWebPushCrypto::EcKey
        @key
      end

      def free : Nil
        LibWebPushCrypto.ec_key_free(@key) unless @key.null?
        @key = Pointer(Void).null.as(LibWebPushCrypto::EcKey)
      end

      def finalize
        free
      end
    end
  end
end

# Минимальный FFI к libcrypto (отдельный lib-блок: свои имена,
# внешние символы OpenSSL — конфликтов со stdlib нет).
@[Link("crypto")]
lib LibWebPushCrypto
  alias EcKey = Void*
  alias EcGroup = Void*
  alias EcPoint = Void*
  alias Bignum = Void*
  alias EvpPkey = Void*
  alias EvpPkeyCtx = Void*
  alias EvpMdCtx = Void*
  alias EvpMd = Void*
  alias EvpCipher = Void*
  alias EvpCipherCtx = Void*
  alias Engine = Void*

  fun ec_key_new_by_curve_name = EC_KEY_new_by_curve_name(nid : Int32) : EcKey
  fun ec_key_generate_key = EC_KEY_generate_key(key : EcKey) : Int32
  fun ec_key_free = EC_KEY_free(key : EcKey)
  fun ec_key_dup = EC_KEY_dup(key : EcKey) : EcKey
  fun ec_key_set_public_key = EC_KEY_set_public_key(key : EcKey, key_pub : EcPoint) : Int32
  fun ec_key_set_private_key = EC_KEY_set_private_key(key : EcKey, priv : Bignum) : Int32
  fun ec_key_get0_public_key = EC_KEY_get0_public_key(key : EcKey) : EcPoint
  fun ec_key_get0_group = EC_KEY_get0_group(key : EcKey) : EcGroup

  fun ec_group_get_order = EC_GROUP_get_order(group : EcGroup, order : Bignum, ctx : Void*) : Int32
  fun ec_point_new = EC_POINT_new(group : EcGroup) : EcPoint
  fun ec_point_free = EC_POINT_free(point : EcPoint)
  fun ec_point_oct2point = EC_POINT_oct2point(group : EcGroup, p : EcPoint, buf : UInt8*, len : LibC::SizeT, ctx : Void*) : Int32
  fun ec_point_point2oct = EC_POINT_point2oct(group : EcGroup, p : EcPoint, form : Int32, buf : UInt8*, len : LibC::SizeT, ctx : Void*) : LibC::SizeT
  fun ec_point_mul = EC_POINT_mul(group : EcGroup, r : EcPoint, n : Bignum, q : EcPoint, m : Bignum, ctx : Void*) : Int32

  fun bn_new = BN_new : Bignum
  fun bn_free = BN_free(a : Bignum)
  fun bn_bin2bn = BN_bin2bn(s : UInt8*, len : Int32, ret : Bignum) : Bignum

  fun evp_pkey_new = EVP_PKEY_new : EvpPkey
  fun evp_pkey_free = EVP_PKEY_free(pkey : EvpPkey)
  fun evp_pkey_assign = EVP_PKEY_assign(pkey : EvpPkey, type : Int32, key : EcKey) : Int32

  fun evp_pkey_ctx_new = EVP_PKEY_CTX_new(pkey : EvpPkey, e : Engine) : EvpPkeyCtx
  fun evp_pkey_ctx_free = EVP_PKEY_CTX_free(ctx : EvpPkeyCtx)
  fun evp_pkey_derive_init = EVP_PKEY_derive_init(ctx : EvpPkeyCtx) : Int32
  fun evp_pkey_derive_set_peer = EVP_PKEY_derive_set_peer(ctx : EvpPkeyCtx, peer : EvpPkey) : Int32
  fun evp_pkey_derive = EVP_PKEY_derive(ctx : EvpPkeyCtx, key : UInt8*, keylen : LibC::SizeT*) : Int32

  fun evp_digest_sign_init = EVP_DigestSignInit(ctx : EvpMdCtx, pctx : EvpPkeyCtx*, type : EvpMd, e : Engine, pkey : EvpPkey) : Int32
  fun evp_digest_sign = EVP_DigestSign(ctx : EvpMdCtx, sigret : UInt8*, siglen : LibC::SizeT*, tbs : UInt8*, tbslen : LibC::SizeT) : Int32

  fun evp_aes_128_gcm = EVP_aes_128_gcm : EvpCipher
  fun evp_encrypt_init_ex = EVP_EncryptInit_ex(ctx : EvpCipherCtx, cipher : EvpCipher, impl : Engine, key : UInt8*, iv : UInt8*) : Int32
  fun evp_cipher_ctx_ctrl = EVP_CIPHER_CTX_ctrl(ctx : EvpCipherCtx, type : Int32, arg : Int32, ptr : Void*) : Int32
  fun evp_encrypt_update = EVP_EncryptUpdate(ctx : EvpCipherCtx, outm : UInt8*, outl : Int32*, inm : UInt8*, inl : Int32) : Int32
  fun evp_encrypt_final_ex = EVP_EncryptFinal_ex(ctx : EvpCipherCtx, outm : UInt8*, outl : Int32*) : Int32
end
