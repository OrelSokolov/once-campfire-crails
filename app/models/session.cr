require "./application_record"
class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour

  has_secure_token

  belongs_to :user

  before_create { self.last_active_at ||= Time.utc }

  # Rails: user.sessions.start!(user_agent:, ip_address:) — the token comes from
  # has_secure_token, last_active_at from the before_create callback above.
  # NOTE: kwargs form — AR has no new(hash) overload (only create/update take a Hash).
  def self.start!(user : User, user_agent : String?, ip_address : String?) : Session
    session = new(
      user_id: user.id.not_nil!,
      user_agent: user_agent,
      ip_address: ip_address)
    session.save!
    session
  end

  # The signed cookie jar may decode values as JSON-wrapped strings; accept both.
  def self.token_from_signed_jar(raw) : String?
    case raw
    when String then raw
    when JSON::Any then raw.as_s?
    else nil
    end
  end
end
