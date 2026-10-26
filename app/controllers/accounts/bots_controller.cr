class Accounts::BotsController < ApplicationController
  helper :bots

  before_action :ensure_can_administer

  @bots : Array(User) = [] of User
  @bot_rooms : Hash(Int64, Array(NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String))))) = {} of Int64 => Array(NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String))))
  @bot : User?

  def new
    @bot = User.new(role: :bot)
  end

  def create
    name = nested("name")
    if name.empty?
      response.status = :unprocessable_entity
      return render(plain: "invalid bot parameters")
    end
    now = Time.utc
    bot = User.new(
      name: name,
      role: :bot,
      status: :active,
      bot_token: User.generate_bot_token,
      created_at: now, updated_at: now)
    bot.save!
    sync_webhook(bot.id!, nested("webhook_url"))
    # The port writes short STI types ('Open') while the oracle seed stores full
    # names ('Rooms::Open'); the opens scope covers both spellings.
    Room.opens.each do |room|
      Membership.new(room_id: room.id!, user_id: bot.id!,
        involvement: "mentions", connections: 0,
        created_at: now, updated_at: now).save!
    end
    redirect_to account_bots_url
  end

  def index
    @bots = User.active_bots.ordered.to_a
    @bots.each do |bot|
      bid = bot.id!
      bot_key = "#{bid}-#{bot.bot_token.to_s}"
      # Covers both type spellings: seed 'Rooms::Direct', port 'Direct'.
      rooms = [] of NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String)))
      Room.visible_for(bot).without_directs.ordered.each do |room|
        rid = room.id!
        text = "curl -d 'Hello!' #{origin}/rooms/#{rid}/#{bot_key}/messages"
        upload = %{curl -F "attachment=@/path/to/file" #{origin}/rooms/#{rid}/#{bot_key}/messages}
        rooms << {legend: room.name.to_s, commands: [
          {icn: "messages-outlined.svg", label: "posting messages", sr: "Copy message command", cmd: text},
          {icn: "attachment.svg", label: "posting attachments", sr: "Copy attachment command", cmd: upload},
        ]}
      end
      @bot_rooms[bid] = rooms
    end
  end

  def edit
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    @bot = User.active_bots.find(params["id"].to_s)
  end

  def update
    bot = User.active_bots.find(params["id"].to_s)
    name = nested("name")
    bot.name = name unless name.empty?
    bot.updated_at = Time.utc
    bot.save!
    sync_webhook(bot.id!, nested("webhook_url"))
    redirect_to account_bots_url
  end

  def destroy
    # role-only scope: deactivated bots stay deletable (the port hard-deletes;
    # the oracle soft-deactivates — see notes/style-parity.md)
    bot = User.where("role = 2").find(params["id"].to_s)
    ActiveRecord::Base.connection.exec(
      "DELETE FROM memberships WHERE user_id = ?", bot.id!)
    ActiveRecord::Base.connection.exec(
      "DELETE FROM webhooks WHERE user_id = ?", bot.id!)
    bot.destroy
    redirect_to account_bots_url
  end

  private def nested(key : String) : String
    nested = params["user"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    nested[key]?.to_s
  end

  # Empty URL deletes the webhook; a non-empty URL is the bot's single webhook row.
  private def sync_webhook(bot_id : Int64, url : String) : Nil
    conn = ActiveRecord::Base.connection
    if url.empty?
      conn.exec("DELETE FROM webhooks WHERE user_id = ?", bot_id)
    else
      now = Time.utc
      existing = conn.query_one?(
        "SELECT id FROM webhooks WHERE user_id = ?", bot_id) { |rs| rs.read(Int64) }
      if existing
        conn.exec("UPDATE webhooks SET url = ?, updated_at = ? WHERE id = ?",
          url, now, existing)
      else
        conn.exec(
          "INSERT INTO webhooks (url, user_id, created_at, updated_at) VALUES (?, ?, ?, ?)",
          url, bot_id, now, now)
      end
    end
  end
end
