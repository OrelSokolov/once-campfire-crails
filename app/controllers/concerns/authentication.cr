# concerns/authentication.rb референса: сессия по signed cookie
# session_token (IdentityCache + DB-epoch), Current.session/user,
# require_authentication, start_new_session_for, signed_id-хелперы.
module Authentication
  @identity_entry : Campfire::IdentityCache::Entry? = nil
  @identity_checked : Bool = false

  # Campfire authentication.rb: protect_from_forgery using: :header_only,
  # with: :exception, unless: -> { authenticated_by.bot_key? } —
  # бот-ключи в URL (не из браузера) защиту отключают.
  def bot_request? : Bool
    params["bot_key"]? != nil
  end

  # Оракул (rails-main, lazy-сессии): protect_against_forgery? в контексте
  # рендера false → формы НЕ содержат embedded authenticity_token (ни у
  # анонимов, ни у залогиненных — проверено живым оракулом, /session/new и
  # /account/edit). Turbo/XHR берут токен из csrf_meta_tags; верификация —
  # Sec-Fetch-Site (header_only), от поля в форме не зависит.
  protected def __csrf_token_field(action : String, method : String) : String
    ""
  end

  def current_session : Session?
    raw = cookies.signed["session_token"]?
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s? # signed jar decodes JSON-wrapped values
            else nil
            end
    return nil unless token
    @identity_checked = true
    @identity_entry = Campfire::IdentityCache.lookup(token, db_epoch)
    # concerns/authentication.rb#authenticated_as: Current.session = session
    # (writer Current.session= в референсе заодно проставляет user).
    Current.session = @identity_entry.try(&.session)
    Current.user = @identity_entry.try(&.user)
    @identity_entry.try(&.session)
  end

  def current_user : User?
    current_session unless @identity_checked
    @identity_entry.try(&.user)
  end

  def require_authentication : Nil
    redirect_to new_session_url unless current_user
  end

  # Rails authentication: start_new_session_for — создаёт сессию и
  # подписывает permanent cookie session_token (sessions#create,
  # first_runs#create).
  def start_new_session_for(user : User) : Nil
    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    # authenticated_as(session): Current.session/user видны хелперам и
    # моделям до конца запроса (между запросами сбрасываются диспетчером).
    Current.session = session
    Current.user = user
    cookies.signed.set("session_token", session.token.not_nil!,
      expires: Time.utc + 20.years, httponly: true, same_site: :lax)
  end

  def remote_ip : String?
    request.headers["X-Forwarded-For"]?.try(&.split(',').first?.try(&.strip)) ||
      request.headers["Remote-Addr"]? || "127.0.0.1"
  end

  # Rails signed_id: generate/verify через MessageVerifier с ключом
  # "active_record/signed_id" (см. campfire-express/src/rails.js: key()).
  # Формат — data-конверт Rails 8.1 (urlsafe b64 без padding).
  def generate_signed_id(user_id : Int64, purpose : String, expires_at : Time? = nil) : String
    CRails.application.message_verifier("active_record/signed_id", url_safe: true)
      .generate(user_id, purpose: purpose, expires_at: expires_at)
  end

  def verify_signed_id(token : String, purpose : String) : Int64?
    # express/verifier: digest sha256, fallback sha1. Верификаторы —
    # мемоизированы на CRails.application (PBKDF2-вывод ключа один раз
    # на процесс, не на каждый запрос).
    value = CRails.application.message_verifier("active_record/signed_id",
      url_safe: true).verified_any(token, purpose: purpose)
    if value.nil?
      value = CRails.application.message_verifier("active_record/signed_id",
        digest: :sha1, url_safe: true).verified_any(token, purpose: purpose)
    end
    if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
      return raw.to_i64
    end
    nil
  end

  # origin(req) референса: схема://host — для session transfer / invite URL.
  def origin : String
    host = request.headers["Host"]? || "localhost"
    "http://#{host}"
  end
end
