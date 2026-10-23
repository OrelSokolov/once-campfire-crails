require "./authentication/session_lookup"

# concerns/authentication.rb референса: Current.session/user,
# require_authentication, start_new_session_for, signed_id-хелперы.
# Cookie→сессия — Authentication::SessionLookup.
module Authentication
  include SessionLookup
  @identity_entry : Campfire::IdentityCache::Entry? = nil
  @identity_checked : Bool = false

  # Campfire authentication.rb: protect_from_forgery using: :header_only,
  # with: :exception, unless: -> { authenticated_by.bot_key? } —
  # защиту отключает ТОЛЬКО успешно аутентифицированный бот-ключ
  # (наличие параметра bot_key ничего не отключает).
  def bot_request? : Bool
    return false unless key = params["bot_key"]?
    !User.authenticate_bot(key.to_s).nil?
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
    return nil unless (entry = find_session_by_cookie)
    @identity_checked = true
    @identity_entry = entry
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

  # request.remote_ip Rails: клиентский IP. Записям X-Forwarded-For
  # верим, только когда сокет-адрес — доверенный прокси (loopback/
  # private-диапазоны); иначе клиент может вписать в сессии и баны
  # произвольный IP (ActionDispatch::RemoteIp так же отбрасывает
  # клиентский XFF от недоверенных пиров).
  def remote_ip : String?
    socket_ip = case addr = request.remote_address
                when Socket::IPAddress then addr.address.to_s
                else nil
                end
    if (fwd = request.headers["X-Forwarded-For"]?) &&
       (client = fwd.split(',').first?.try(&.strip)) && !client.empty? &&
       socket_ip.try { |ip| trusted_proxy?(ip) }
      return client
    end
    socket_ip || request.headers["Remote-Addr"]? || "127.0.0.1"
  end

  private def trusted_proxy?(ip : String) : Bool
    # loopback и private/link-local/CGNAT — всё, что Opengraph.public_ip?
    # считает непубличным (fail closed на мусорных значениях).
    !Opengraph.public_ip?(ip)
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

  # origin(req) референса: схема://host — для session transfer / invite
  # URL. Схема — как req.protocol express-оракула (за прокси это
  # X-Forwarded-Proto), а не хардкод http://.
  def origin : String
    host = request.headers["Host"]? || "localhost"
    scheme = request.headers["X-Forwarded-Proto"]?
      .try(&.split(',').first?.try(&.strip)) || "http"
    "#{scheme}://#{host}"
  end
end
