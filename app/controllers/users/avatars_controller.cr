# Avatar tokens are Rails signed_ids verified with a
# PBKDF2-SHA256(secret, "active_record/signed_id", 1000, 64)-derived
# HMAC-SHA256 key (campfire-express src/rails.js: key()/verifyId).
class Users::AvatarsController < ApplicationController

  allow_unauthenticated_access # avatars are publicly linked

  def show
    raw_token = params["token"].to_s
    # Numeric avatar ids are for authenticated requests only (message pages
    # render /users/<id>/avatar); the signed_id token is the public path.
    user_id = if raw_token.matches?(/\A\d+\z/) && current_user
                raw_token.to_i64
              else
                verify_signed_id(raw_token, purpose: "user/avatar")
              end
    return render(plain: "invalid avatar token", status: 404) if user_id.nil?

    # The public token path is cached whole (bytes + Content-Type); avatars
    # are frequent and viewer-independent, invalidated by DB epoch (cf. PageCache).
    cache_epoch = db_epoch
    if (hit = AvatarCache.get(raw_token, cache_epoch))
      response.headers["Cache-Control"] = "public, max-age=1800"
      return render(html: hit.bytes, content_type: hit.content_type)
    end

    user = User.find?(user_id)
    blob = user.try(&.avatar_blob)
    unless blob
      if user.try(&.role) == 2
        return render_default_bot(user, raw_token, cache_epoch,
          public_path: !!PublicCache.avatar_token_path?(request.path))
      end
      return render_initials(user, raw_token, cache_epoch,
        public_path: !!PublicCache.avatar_token_path?(request.path))
    end

    key = blob.not_nil!.key!
    path = File.join(storage_root, key[0, 2], key[2, 2], key)
    return render(plain: "avatar file missing", status: 404) unless File.exists?(path)

    content_type = blob.not_nil!.content_type.to_s
    # Dangerous content types are forced to octet-stream/attachment (as in
    # ActiveStorageController#serving_attributes): an SVG/HTML avatar on the
    # public path is stored XSS.
    if ActiveStorageController::BINARY_TYPES.includes?(content_type.split(';').first.to_s)
      content_type = "application/octet-stream"
      response.headers["Content-Disposition"] = "attachment"
    end
    if (variant = avatar_square_variant(blob.not_nil!, path))
      path, content_type = variant
    end
    bytes = File.read(path)
    AvatarCache.set(raw_token, cache_epoch, bytes, content_type)
    PublicCache.set(PublicCache.key(request), bytes, content_type) if public_token_path?
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: bytes, content_type: content_type)
  end

  # Lazily processed square variant (webp, 512x512) with a disk cache under
  # variants/<key>/<variation.key>, as in ActiveStorage.
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

  # The token path is viewer-independent (public); numeric ids never reach PublicCache.
  private def public_token_path? : Bool
    !!PublicCache.avatar_token_path?(request.path)
  end

  # Storage root: the harness mounts the seed at /rails/storage/files;
  # configurable via CAMPFIRE_STORAGE_ROOT locally.
  private def storage_root : String
    ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
  end

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

  private def render_initials(user : User?, cache_key : String? = nil,
                              cache_epoch : String? = nil,
                              public_path : Bool = false) : Nil
    svg = initials_svg(user)
    if cache_key && cache_epoch
      AvatarCache.set(cache_key, cache_epoch, svg, "image/svg+xml")
    end
    PublicCache.set(PublicCache.key(request), svg, "image/svg+xml") if public_path
    # Explicit content_type argument: render(html:) defaults to text/html
    # and would overwrite the header set above.
    response.headers["Cache-Control"] = "public, max-age=1800"
    render(html: svg, content_type: "image/svg+xml")
  end
end
