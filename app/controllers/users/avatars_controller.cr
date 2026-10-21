# GET /users/:token/avatar — аватар по Rails signed_id токену
# (контракт: 200, image/*, байты валидны ffprobe; токен из labels вида
# eyJfcmFpbHMiOnsiZGF0YSI6MTQ5MDg3NjU5LCJwdXIiOiJ1c2VyL2F2YXRhciJ9fQ--<hmac>).
#
# Ключ подписи: PBKDF2-SHA256(secret, "active_record/signed_id", 1000, 64),
# HMAC-SHA256 (см. campfire-express/src/rails.js: key()/verifyId).
class Users::AvatarsController < ApplicationController
  include AvatarsHelpers

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
      # Референс: без аватара бот получает default-bot-avatar.svg,
      # остальные — SVG-инициалы (render_initials), не 404 — страницы
      # сообщений всегда линкуют /users/<id>/avatar.
      if user.try(&.role) == 2
        return render_default_bot(user, raw_token, cache_epoch,
          public_path: !!PublicCache.avatar_token_path?(request.path))
      end
      return render_initials(user, raw_token, cache_epoch,
        public_path: !!PublicCache.avatar_token_path?(request.path))
    end

    key = blob.not_nil!.key.not_nil!
    path = File.join(storage_root, key[0, 2], key[2, 2], key)
    return render(plain: "avatar file missing", status: 404) unless File.exists?(path)

    # avatar_variant референса: variant :square (webp, 512×512) для
    # variable-картинок (send_webp_blob_file), оригинал — остальному.
    content_type = blob.not_nil!.content_type.to_s
    if (variant = avatar_square_variant(blob.not_nil!, path))
      path, content_type = variant
    end
    bytes = File.read(path)
    AvatarCache.set(raw_token, cache_epoch, bytes, content_type)
    PublicCache.set(PublicCache.key(request), bytes, content_type) if public_token_path?
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: bytes, content_type: content_type)
  end

  # User::Avatar: has_one_attached :avatar do variant :square,
  # resize_to_limit: [512, 512], format: :webp end. Ленивая обработка с
  # дисковым кешем variants/<key>/<variation.key> (как в ActiveStorage).
  private def avatar_square_variant(blob : ActiveStorageBlob,
                                    source_path : String) : {String, String}?
    return nil unless ActiveStorage::Blob::VARIABLE_CONTENT_TYPES.includes?(
      blob.content_type.to_s)
    transformations = {} of String => ActiveStorage::Variation::Value
    transformations["format"] = "webp"
    transformations["resize_to_limit"] = [512, 512]
    variation = ActiveStorage::Variation.new(transformations)
    service = ActiveStorage.service
    return nil unless service.is_a?(ActiveStorage::DiskService)
    variant_key = "variants/#{blob.key}/#{variation.key}"
    unless service.exist?(variant_key)
      ext = File.extname(blob.filename.to_s).lchop('.')
      bytes = variation.transform(File.read(source_path), ext.empty? ? "png" : ext)
      service.upload(variant_key, bytes, content_type: "image/webp")
    end
    {service.path_for(variant_key), "image/webp"}
  rescue ex : Exception
    nil
  end

  # Токен-путь публичен (не зависит от зрителя): числовой id — только
  # для авторизованных, в PublicCache не попадает никогда.
  private def public_token_path? : Bool
    !!PublicCache.avatar_token_path?(request.path)
  end

  # Storage root: harness монтирует сид в /rails/storage/files; локально —
  # настраивается переменной.
  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end

  # render_default_bot: send_file app/assets/images/default-bot-avatar.svg
  # референса (пребилд в public/assets, content-type image/svg+xml).
  private def render_default_bot(user : User?, cache_key : String? = nil,
                                 cache_epoch : String? = nil,
                                 public_path : Bool = false) : Nil
    file = File.join("public", ChatLayout.asset("default-bot-avatar.svg")
      .lchop("/"))
    return render(plain: "default bot avatar missing", status: 404) unless File.exists?(file)
    svg = File.read(file)
    if cache_key && cache_epoch
      AvatarCache.set(cache_key, cache_epoch, svg, "image/svg+xml")
    end
    PublicCache.set(PublicCache.key(request), svg, "image/svg+xml") if public_path
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: svg, content_type: "image/svg+xml")
  end

  # users/avatars_helper.rb + show.svg.erb референса — SVG-инициалы
  # (initials_svg, AvatarsHelpers); cache_epoch передаётся из show — SVG
  # тоже кэшируется по токену; public_path — дополнительно в PublicCache.
  private def render_initials(user : User?, cache_key : String? = nil,
                              cache_epoch : String? = nil,
                              public_path : Bool = false) : Nil
    svg = initials_svg(user)
    if cache_key && cache_epoch
      AvatarCache.set(cache_key, cache_epoch, svg, "image/svg+xml")
    end
    PublicCache.set(PublicCache.key(request), svg, "image/svg+xml") if public_path
    # content_type: явный аргумент — render(html:) по умолчанию ставит
    # text/html и затирает выставленный заранее заголовок.
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: svg, content_type: "image/svg+xml")
  end
end
