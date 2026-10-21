# /account/bots — чат-боты (референс: routes.js /account/bots* +
# bot_form.eta/bots.eta): создание (role=2 + bot_token), список с
# curl-командами, переименование. Только администратор.
class Accounts::BotsController < ApplicationController
  include BotsHelpers

  before_action :require_admin

  # index.html.erb: боты + curl-команды по их комнатам.
  @bots : Array(User) = [] of User
  @bot_rooms : Hash(Int64, Array(NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String))))) = {} of Int64 => Array(NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String))))
  # new.html.erb / edit.html.erb: nil для new, бот для edit.
  @bot : User?

  # GET /account/bots/new — форма (label "Name the bot" через
  # placeholder; smoke: getByPlaceholder + кнопка "Save changes").
  def new
    @bot = nil
  end

  # POST /account/bots — create: role=2, bot_token = hex(6 байт)
  # (routes.js: randomBytes(6).toString("hex")).
  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    name = nested("name")
    if name.empty?
      response.status = :unprocessable_entity
      return render(plain: "invalid bot parameters")
    end
    now = Time.utc
    bot = User.new(
      name: name,
      role: 2,
      status: 0,
      bot_token: Random::Secure.hex(6),
      created_at: now, updated_at: now)
    bot.save!
    sync_webhook(bot.id.not_nil!, nested("webhook_url"))
    # createUser эталона (domain.js): новый пользователь (включая бота)
    # получает membership во все Rooms::Open (involvement "mentions").
    # STI-порт пишет короткий type ('Open'), сид хранит полный
    # ('Rooms::Open') — scope opens покрывает оба написания.
    Room.opens.each do |room|
      Membership.new(room_id: room.id.not_nil!, user_id: bot.id.not_nil!,
        involvement: "mentions", connections: 0,
        created_at: now, updated_at: now).save!
    end
    redirect_to account_bots_path
  end

  # GET /account/bots — список ботов с curl-командами по комнатам
  # (bots.eta: заголовок с bot+add, аватары, pencil-edit, поля с
  # иконками messages-outlined/attachment и copy-кнопками).
  def index
    # _bot: User.active_bots.ordered.
    @bots = User.active_bots.ordered.to_a
    @bots.each do |bot|
      bid = bot.id.not_nil!
      bot_key = "#{bid}-#{bot.bot_token.to_s}"
      # _bot.html.erb: bot.rooms.without_directs.ordered — без Direct
      # (сид: 'Rooms::Direct', наши: 'Direct'), по LOWER(name).
      rooms = [] of NamedTuple(legend: String, commands: Array(NamedTuple(icn: String, label: String, sr: String, cmd: String)))
      Room.visible_for(bot).without_directs.ordered.each do |room|
        rid = room.id.not_nil!
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

  # GET /account/bots/:id/edit — форма с текущим именем.
  def edit
    bot = User.where("id = ? AND role = 2 AND status = 0",
      params["id"].to_s.to_i64).take
    return head(:not_found) unless bot
    @bot = bot
  end

  # PATCH /account/bots/:id — rename.
  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    bot = User.where("id = ? AND role = 2 AND status = 0",
      params["id"].to_s.to_i64).take
    return head(:not_found) unless bot
    name = nested("name")
    bot.name = name unless name.empty?
    bot.updated_at = Time.utc
    bot.save!
    sync_webhook(bot.id.not_nil!, nested("webhook_url"))
    redirect_to account_bots_path
  end

  # DELETE /account/bots/:id — удаление бота (bot_form.eta delete-панель).
  def destroy
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    bot = User.where("id = ? AND role = 2", params["id"].to_s.to_i64).take
    return head(:not_found) unless bot
    ActiveRecord::Base.connection.exec(
      "DELETE FROM memberships WHERE user_id = ?", bot.id.not_nil!)
    ActiveRecord::Base.connection.exec(
      "DELETE FROM webhooks WHERE user_id = ?", bot.id.not_nil!)
    bot.destroy
    redirect_to account_bots_path
  end

  # ————— приватное контроллера (не для шаблонов) —————

  private def nested(key : String) : String
    nested = params["user"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    nested[key]?.to_s
  end

  # Webhook бота (routes.js эталона): пустой URL — удалить, непустой —
  # единственная запись webhooks для бота.
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
