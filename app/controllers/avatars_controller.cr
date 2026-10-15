# GET /users/:token/avatar — аватар по Rails signed_id токену
# (контракт: 200, image/*, байты валидны ffprobe; токен из labels вида
# eyJfcmFpbHMiOnsiZGF0YSI6MTQ5MDg3NjU5LCJwdXIiOiJ1c2VyL2F2YXRhciJ9fQ--<hmac>).
#
# Ключ подписи: PBKDF2-SHA256(secret, "active_record/signed_id", 1000, 64),
# HMAC-SHA256 (см. campfire-express/src/rails.js: key()/verifyId).
class AvatarsController < ApplicationController
  skip_before_action :require_authentication # аватары публично линкуются

  def show
    raw_token = params["token"].to_s
    # Числовой id аватара — только для авторизованных (страницы сообщений
    # рендерят /users/<id>/avatar); токен signed_id — публичный путь.
    user_id = if raw_token.matches?(/\A\d+\z/) && current_user
                raw_token.to_i64
              else
                verify_signed_id(raw_token, purpose: "user/avatar")
              end
    return render(plain: "invalid avatar token", status: 404) if user_id.nil?

    # Публичный токен-путь кэшируется целиком (байты + Content-Type):
    # аватары запрашиваются часто и не зависят от зрителя. Инвалидация —
    # DB-эпоха (ср. PageCache): смена аватара — чужой коммит.
    cache_epoch = db_epoch
    if (hit = AvatarCache.get(raw_token, cache_epoch))
      response.headers["Cache-Control"] = "public, max-age=1800"
      return render(html: hit.bytes, content_type: hit.content_type)
    end

    user = User.find?(user_id)
    blob = user.try(&.avatar_blob)
    unless blob
      # Референс: без аватара рендерятся SVG-инициалы (render_initials),
      # не 404 — страницы сообщений всегда линкуют /users/<id>/avatar.
      return render_initials(user, raw_token, cache_epoch)
    end

    key = blob.not_nil!.key.not_nil!
    path = File.join(storage_root, key[0, 2], key[2, 2], key)
    return render(plain: "avatar file missing", status: 404) unless File.exists?(path)

    content_type = blob.not_nil!.content_type.to_s
    bytes = File.read(path)
    AvatarCache.set(raw_token, cache_epoch, bytes, content_type)
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: bytes, content_type: content_type)
  end

  # Storage root: harness монтирует сид в /rails/storage/files; локально —
  # настраивается переменной.
  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end

  # users/avatars/show.svg.erb референса: квадрат с инициалами имени.
  # cache_epoch передаётся из show — SVG тоже кэшируется по токену.
  private def render_initials(user : User?, cache_key : String? = nil,
                              cache_epoch : String? = nil) : Nil
    name = user.try(&.name).to_s
    initials = name.split(/\s+/).reject(&.empty?)
      .map(&.[0]?.try(&.upcase).to_s).join[0, 2]? || ""
    hue = name.hash.abs % 360
    svg = String.build do |io|
      io << %(<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">)
      io << %(<rect width="256" height="256" fill="hsl(#{hue}, 40%, 45%)"/>)
      io << %(<text x="50%" y="54%" dominant-baseline="middle" text-anchor="middle" )
      io << %(font-family="system-ui, sans-serif" font-size="104" font-weight="600" fill="#fff">)
      io << HTML.escape(initials) << %(</text></svg>)
    end
    if cache_key && cache_epoch
      AvatarCache.set(cache_key, cache_epoch, svg, "image/svg+xml")
    end
    # content_type: явный аргумент — render(html:) по умолчанию ставит
    # text/html и затирает выставленный заранее заголовок.
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: svg, content_type: "image/svg+xml")
  end
end
