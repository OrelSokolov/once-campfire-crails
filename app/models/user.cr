require "./application_record"
class User < ApplicationRecord
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
