# Установка Campfire при первом запуске (порт app/models/first_run.rb
# референса + express routes.js): создаёт аккаунт, админ-пользователя,
# комнату "All Talk" (Rooms::Open) с membership. Присутствие name/
# email_address/password — аналог User-валидаций референса: пустые
# значения → RecordInvalid.
class FirstRun
  ACCOUNT_NAME    = "Campfire"
  FIRST_ROOM_NAME = "All Talk"

  def self.create!(user_params : ActionController::Parameters) : User
    name = user_params["name"].to_s
    email_address = user_params["email_address"].to_s
    password = user_params["password"].to_s

    now = Time.utc
    user = User.new(
      name: name,
      email_address: email_address,
      password_digest: Crypto::Bcrypt::Password.create(password, cost: 10).to_s,
      role: 1, # administrator
      status: 0,
      created_at: now, updated_at: now)
    user.errors.add("name", "can't be blank", :blank) if name.empty?
    user.errors.add("email_address", "can't be blank", :blank) if email_address.empty?
    user.errors.add("password", "can't be blank", :blank) if password.empty?
    raise ActiveRecord::RecordInvalid.new(user) unless user.errors.empty?

    # join_code — base64url без padding (routes.js: randomBytes(18)
    # .toString("base64url")) — безопасен в path.
    Account.new(
      name: ACCOUNT_NAME,
      join_code: Base64.urlsafe_encode(Random::Secure.random_bytes(18), padding: false),
      created_at: now, updated_at: now).save!
    user.save!

    room = Rooms::Open.new(
      name: FIRST_ROOM_NAME,
      creator_id: user.id.not_nil!,
      created_at: now, updated_at: now)
    room.save!

    Membership.new(room_id: room.id.not_nil!, user_id: user.id.not_nil!,
      involvement: "mentions", # Room#default_involvement референса
      connections: 0,
      created_at: now, updated_at: now).save!

    user
  end
end
