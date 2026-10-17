abstract class ApplicationController < ActionController::Base
  @db_epoch : String? = nil
  @identity_entry : Campfire::IdentityCache::Entry? = nil
  @identity_checked : Bool = false

  before_action :require_authentication

  # Campfire authentication.rb: protect_from_forgery using: :header_only,
  # with: :exception, unless: -> { authenticated_by.bot_key? } —
  # Sec-Fetch-Site-защита Rails 8.2 (без токенов в формах), бот-ключи
  # в URL (не из браузера) защиту отключают.
  protect_from_forgery using: :header_only, with: :exception, unless: :bot_request?

  def bot_request? : Bool
    params["bot_key"]? != nil
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
    @identity_entry.try(&.session)
  end

  def current_user : User?
    current_session unless @identity_checked
    @identity_entry.try(&.user)
  end

  # DB-epoch запроса (PRAGMA data_version, см. PageCache): мемо на время
  # запроса — аутентификация и page-cache видят одну эпоху, PRAGMA
  # выполняется один раз.
  def db_epoch : String
    @db_epoch ||= PageCache.epoch
  end

  def require_authentication : Nil
    redirect_to "/session/new" unless current_user
  end

  # Rails authentication: start_new_session_for — создаёт сессию и
  # подписывает permanent cookie session_token (sessions#create,
  # first_runs#create).
  def start_new_session_for(user : User) : Nil
    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
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

  # Отдача кэшированной страницы: If-None-Match → 304; Accept-Encoding
  # gzip → сжатое представление (лениво, живёт в Page). Тело — сырые
  # байты (gzip-строка может быть невалидным UTF-8 — Crystal пишет
  # байты как есть).
  def send_page(page : Campfire::PageCache::Page) : Nil
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    response.headers["ETag"] = page.etag
    response.headers["Cache-Control"] = "no-cache"
    if request.headers["If-None-Match"]? == page.etag
      # render(plain:) сбрасывает статус — передаём аргументом
      return render(plain: "", status: :not_modified)
    end
    if request.headers["Accept-Encoding"]?.to_s.includes?("gzip")
      response.headers["Content-Encoding"] = "gzip"
      response.headers["Vary"] = "Accept-Encoding"
      render(html: page.gzip)
    else
      render(html: page.bytes)
    end
  end
end
