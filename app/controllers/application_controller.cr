abstract class ApplicationController < ActionController::Base
  before_action :require_authentication

  def current_session : Session?
    raw = cookies.signed["session_token"]?
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s? # signed jar decodes JSON-wrapped values
            else nil
            end
    return nil unless token
    Session.where("token = ?", token).take
  end

  def current_user : User?
    session = current_session
    return nil unless session
    user_id = session.user_id
    return nil unless user_id
    User.find?(user_id)
  end

  def require_authentication : Nil
    redirect_to "/session/new" unless current_user
  end

  def remote_ip : String?
    request.headers["X-Forwarded-For"]?.try(&.split(',').first?.try(&.strip)) ||
      request.headers["Remote-Addr"]? || "127.0.0.1"
  end

  # Rails signed_id: generate/verify через MessageVerifier с ключом
  # "active_record/signed_id" (см. campfire-express/src/rails.js: key()).
  # Формат — data-конверт Rails 8.1 (urlsafe b64 без padding).
  def generate_signed_id(user_id : Int64, purpose : String, expires_at : Time? = nil) : String
    verifier_for_signed_ids.generate(user_id, purpose: purpose, expires_at: expires_at)
  end

  def verify_signed_id(token : String, purpose : String) : Int64?
    # express/verifier: digest sha256, fallback sha1
    value = verifier_for_signed_ids.verified_any(token, purpose: purpose)
    if value.nil?
      value = verifier_for_signed_ids(digest: :sha1).verified_any(token, purpose: purpose)
    end
    if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
      return raw.to_i64
    end
    nil
  end

  private def verifier_for_signed_ids(digest : Symbol = :sha256)
    secret = ENV["SECRET_KEY_BASE"]? ||
             raise RuntimeError.new("SECRET_KEY_BASE is not configured")
    key = ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(secret, iterations: 1000, digest: :sha256))
      .generate_key("active_record/signed_id")
    ActiveSupport::MessageVerifier.new(key, url_safe: true, digest: digest)
  end

  # origin(req) референса: схема://host — для session transfer / invite URL.
  def origin : String
    host = request.headers["Host"]? || "localhost"
    "http://#{host}"
  end
end
