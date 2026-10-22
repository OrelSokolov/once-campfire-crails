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

  # SecureRandom.alphanumeric(12) Rails (user/bot.rb generate_bot_token):
  # [A-Za-z0-9]{12} ≈ 71 бит энтропии (hex(6) давал 48).
  BOT_TOKEN_CHARSET = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a

  def self.generate_bot_token : String
    String.build(12) do |io|
      12.times { io << BOT_TOKEN_CHARSET[Random::Secure.rand(BOT_TOKEN_CHARSET.size)] }
    end
  end

  # User.authenticate_bot оракула: "<id>-<token>" → активный бот.
  # Токен сравнивается constant-time (Crypto::Subtle), не SQL-строкой.
  def self.authenticate_bot(bot_key : String) : User?
    dash = bot_key.index('-')
    return nil unless dash && (bot_id = bot_key[0, dash].to_i64?)
    bot = where("id = ? AND role = 2 AND status = 0", bot_id).take
    return nil unless bot
    token = bot.bot_token.to_s
    return nil if token.empty?
    Crypto::Subtle.constant_time_compare(token, bot_key[(dash + 1)..]) ? bot : nil
  end

  # Rails: User.active.authenticate_by(email_address:, password:) —
  # bcrypt compare against password_digest (status 0 = active).
  # authenticate_by при ненайденном юзере всё равно хеширует пароль
  # (secure_password.rb: "helps mitigate timing-based enumeration") —
  # порт делает тот же dummy-bcrypt, чтобы ответ на несуществующий
  # email не отличался по времени от неверного пароля.
  DUMMY_BCRYPT = Crypto::Bcrypt::Password.create("campfire-timing-guard", cost: 10).to_s

  def self.authenticate(email_address : String, password : String) : User?
    user = active.where("email_address = ?", email_address).take
    digest = user ? user.password_digest.to_s : DUMMY_BCRYPT
    if digest.empty?
      # пустой digest (бот без пароля): bcrypt по ветке nil-user уже
      # отработал выше только для nil-юзера; здесь дожимаем время
      # dummy-хешем для одинаковой формы ответа
      digest = DUMMY_BCRYPT
    end
    begin
      bcrypt = Crypto::Bcrypt::Password.new(digest)
    rescue Crypto::Bcrypt::Error
      bcrypt = Crypto::Bcrypt::Password.new(DUMMY_BCRYPT)
    end
    bcrypt.verify(password) && user ? user : nil
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
    # apply_ban референса: close_remote_connections — рвём live-сокеты
    # забаненного ПОСЛЕ commit (рано закрытый сокет реконнектнится и
    # перечитает ещё живую сессию).
    close_remote_connections
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

  # user.rb:48-49 + 71-72 референса: reset/close_remote_connections —
  # живые cable-сокеты юзера закрываются через internal channel
  # (ActionCable::RemoteConnections в шарде action_cable_cr; CableBus
  # доставляет disconnect во все fork-воркеры). reconnect: true — клиент
  # перезапустит /cable (логаут), false — не должен (бан/деактивация).
  def reset_remote_connections : Nil
    close_remote_connections reconnect: true
  end

  def close_remote_connections(reconnect : Bool = false) : Nil
    ActionCable.server.remote_connections
      .where(current_user: id.not_nil!.to_s).disconnect(reconnect: reconnect)
  end
end
