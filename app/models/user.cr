require "./application_record"
class User < ApplicationRecord
  has_many :memberships, foreign_key: "user_id"
  has_many :rooms, through: :memberships
  has_many :sessions, foreign_key: "user_id"
  has_many :bans, foreign_key: "user_id"
  has_many :messages, foreign_key: "creator_id"
  has_many :searches, foreign_key: "user_id", class_name: "Search"

  preloadable_attachment :avatar

  ar_enum :status, {active: 0, deactivated: 1, banned: 2}, default: :active
  # User::Role (user/role.rb) declares this in the concern; ar_enum runs only
  # in the class body.
  ar_enum :role, [ :member, :administrator, :bot ]

  after_create_commit :grant_membership_to_open_rooms

  scope(:active)     { where("status = 0") }
  scope(:active_bots) { active.where("role = 2") }
  scope(:ordered)    { order("LOWER(name)") }
  # Oracle User::Bannable: visible_to — admins also see banned users.
  scope(:visible_to) { |user| user.can_administer? ? where("status IN (0, 2)") : where("status = 0") }

  # authenticate_by hashes the password even for an unknown user (secure_password.rb:
  # "helps mitigate timing-based enumeration") — the port runs the same dummy bcrypt.
  DUMMY_BCRYPT = Crypto::Bcrypt::Password.create("campfire-timing-guard", cost: 10).to_s

  def self.authenticate(email_address : String, password : String) : User?
    user = active.where("email_address = ?", email_address).take
    digest = user ? user.password_digest.to_s : DUMMY_BCRYPT
    if digest.empty?
      # Empty digest (a bot without a password): spend the dummy-bcrypt time so the
      # response shape stays uniform.
      digest = DUMMY_BCRYPT
    end
    begin
      bcrypt = Crypto::Bcrypt::Password.new(digest)
    rescue Crypto::Bcrypt::Error
      bcrypt = Crypto::Bcrypt::Password.new(DUMMY_BCRYPT)
    end
    bcrypt.verify(password) && user ? user : nil
  end

  def reset_remote_connections : Nil
    close_remote_connections reconnect: true
  end

  # Oracle: has_many :reachable_messages, through: :rooms, source: :messages
  # (boosts authorization scope). The shard composes through over a direct
  # has_many only — `rooms` is itself a through association, so the chained
  # subquery is written out (see notes/style-parity.md).
  def reachable_messages : ActiveRecord::Relation(Message)
    Message.where(
      %(room_id IN (SELECT room_id FROM memberships WHERE user_id = ?)),
      id || -1_i64)
  end

  def close_remote_connections(reconnect : Bool = false) : Nil
    ActionCable.server.remote_connections
      .where(current_user: id.not_nil!.to_s).disconnect(reconnect: reconnect)
  end

  private def grant_membership_to_open_rooms : Nil
    # One statement, which SQLite runs under the write lock (oracle user.rb):
    # membership in every open room, duplicates skipped. involvement falls
    # back to the column default ('mentions' — Room#default_involvement).
    # The port stores the STI type in two spellings, so cover both.
    now = Time.utc
    ActiveRecord::Base.connection.exec(
      "insert into memberships (room_id, user_id, created_at, updated_at) " \
      "select id, ?, ?, ? from rooms where type in ('Open', 'Rooms::Open') " \
      "on conflict do nothing",
      id.not_nil!, now, now)
  end
end
