# First-run Campfire setup: creates the account, the administrator user and the
# "All Talk" room with a membership. Presence checks mirror the reference's User
# validations: empty values raise RecordInvalid.
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
      role: :administrator,
      created_at: now, updated_at: now)
    user.errors.add("name", "can't be blank", :blank) if name.empty?
    user.errors.add("email_address", "can't be blank", :blank) if email_address.empty?
    user.errors.add("password", "can't be blank", :blank) if password.empty?
    raise ActiveRecord::RecordInvalid.new(user) unless user.errors.empty?

    # join_code comes from Account::Joinable's before_create (alphanumeric 12,
    # grouped by 4 with dashes — the oracle's SecureRandom.alphanumeric(12)).
    Account.new(
      name: ACCOUNT_NAME,
      created_at: now, updated_at: now).save!
    user.save!

    room = Rooms::Open.new(
      name: FIRST_ROOM_NAME,
      creator_id: user.id.not_nil!,
      created_at: now, updated_at: now)
    room.save!
    # The room's after_save_commit grants membership to every active user
    # (rooms/open.cr) — the administrator included, involvement 'mentions'.

    user
  end
end
