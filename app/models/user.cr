class User < ActiveRecord::Base
  has_many :memberships, foreign_key: "user_id"
  has_many :sessions, foreign_key: "user_id"
  has_many :messages, foreign_key: "creator_id"
  has_many :searches, foreign_key: "user_id", class_name: "Search"

  preloadable_attachment :avatar

  # user.rb / user/bot.rb референса: ordered, active (bannable),
  # active_bots (active.where(role: :bot); в порте role=2, status=0).
  scope(:active)     { where("status = 0") }
  scope(:active_bots) { active.where("role = 2") }
  scope(:ordered)    { order("LOWER(name)") }

  # Rails: User.active.authenticate_by(email_address:, password:) —
  # bcrypt compare against password_digest (status 0 = active).
  def self.authenticate(email_address : String, password : String) : User?
    user = active.where("email_address = ?", email_address).take
    return nil unless user
    digest = user.password_digest.to_s
    return nil if digest.empty?
    begin
      bcrypt = Crypto::Bcrypt::Password.new(digest)
    rescue Crypto::Bcrypt::Error
      return nil
    end
    bcrypt.verify(password) ? user : nil
  end

  # Единственный webhook бота (таблица webhooks; user_id, url).
  def webhook_url : String?
    ActiveRecord::Base.connection.query_one?(
      "SELECT url FROM webhooks WHERE user_id = ?", id.not_nil!) { |rs| rs.read(String?) }
  end
end
