class Accounts::BotsController < ApplicationController
  helper :bots

  before_action :ensure_can_administer

  @bots : Array(User) = [] of User
  @bot : User?

  # Oracle app/views/accounts/bots/_bot|_form.html.erb: index renders the
  # bot collection, new/edit share the form partial. The rooms loop of the
  # _bot partial (oracle: bot.rooms.without_directs.ordered) queries
  # Room.visible_for directly — the same per-bot SQL as the oracle.
  compile_partials({
    "accounts/bots/bot"  => {path: "app/views/accounts/bots/_bot.html.erb",
                             locals: {"bot" => User}},
    "accounts/bots/form" => {path: "app/views/accounts/bots/_form.html.erb",
                             locals: {"form" => ActionView::Helpers::FormHelper::FormBuilder,
                                      "bot"  => User}},
  })

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
    # Open-room memberships come from the User after_create_commit
    # callback (grant_membership_to_open_rooms), as in the oracle —
    # a manual loop here double-inserts and trips the unique index.
    redirect_to account_bots_url
  end

  def index
    @bots = User.active_bots.ordered.to_a
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
