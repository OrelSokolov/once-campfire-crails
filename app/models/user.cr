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

  # User::Role референса: enum role (member/administrator/bot; в порте
  # role — integer: 0/1/2).
  def administrator? : Bool
    role == 1
  end

  def can_administer?(record : Room? = nil) : Bool
    administrator? || record.try(&.creator) == self || record.try(&.new_record?) == true
  end

  def can_administer?(message : Message?) : Bool
    administrator? || message.try(&.creator) == self || message.try(&.new_record?) == true
  end

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

  # User::Bannable#ban (user/bannable.rb референса, bannable-контракт
  # express routes.js): транзакция — bans из IP-адресов сессий юзера
  # (DISTINCT, без пустых), удаление сессий (разлогин), статус banned
  # (2). Контент удаляется асинхронно джобой remove_banned_content
  # (RemoveBannedContentJob) — постановка строго после commit, как
  # notify в MessageCreator.
  def ban : Nil
    uid = id.not_nil!
    now = Time.utc
    Campfire::WriteQueue.perform do
      ActiveRecord::Base.transaction do
        conn = ActiveRecord::Base.__session # pinned-коннект транзакции
        conn.query_all(
          "SELECT DISTINCT ip_address FROM sessions " \
          "WHERE user_id = ? AND ip_address IS NOT NULL AND ip_address <> ''", uid) do |rs|
          rs.read(String)
        end.each do |ip|
          conn.exec(
            "INSERT INTO bans (user_id, ip_address, created_at, updated_at) VALUES (?, ?, ?, ?)",
            uid, ip, now, now)
        end
        conn.exec("DELETE FROM sessions WHERE user_id = ?", uid)
        conn.exec("UPDATE users SET status = 2, updated_at = ? WHERE id = ?", now, uid)
      end
    end
    Campfire::JobQueue.enqueue_batch([{"remove_banned_content", %({"user_id":#{uid}})}])
  end

  # User::Bannable#unban: bans.delete_all + active! (статус 0).
  def unban : Nil
    uid = id.not_nil!
    now = Time.utc
    Campfire::WriteQueue.perform do
      conn = ActiveRecord::Base.connection
      conn.exec("DELETE FROM bans WHERE user_id = ?", uid)
      conn.exec("UPDATE users SET status = 0, updated_at = ? WHERE id = ?", now, uid)
    end
  end
end
