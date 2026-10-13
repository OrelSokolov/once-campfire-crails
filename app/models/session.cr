class Session < ActiveRecord::Base
  belongs_to :user

  # Rails: user.sessions.start!(user_agent:, ip_address:) — creates the
  # session record with a fresh token. NOTE: kwargs form — AR has no
  # new(hash) overload (only create/update take a Hash).
  def self.start!(user : User, user_agent : String?, ip_address : String?) : Session
    session = new(
      user_id: user.id.not_nil!,
      token: Random::Secure.base64(24),
      user_agent: user_agent,
      ip_address: ip_address,
      last_active_at: Time.utc,
    )
    session.save!
    session
  end
end
