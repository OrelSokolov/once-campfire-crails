# /account/bots — чат-боты (референс: routes.js /account/bots* +
# bot_form.eta/bots.eta): создание (role=2 + bot_token), список с
# curl-командами, переименование. Только администратор.
class BotsController < ApplicationController
  before_action :require_admin

  # GET /account/bots/new — форма (label "Name the bot" через
  # placeholder; smoke: getByPlaceholder + кнопка "Save changes").
  def new
    render(html: String.build { |io| bot_form(io, nil) })
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
    # ('Rooms::Open') — матчим оба.
    Room.where("type IN ('Open', 'Rooms::Open')").each do |room|
      Membership.new(room_id: room.id.not_nil!, user_id: bot.id.not_nil!,
        involvement: "mentions", connections: 0,
        created_at: now, updated_at: now).save!
    end
    redirect_to "/account/bots"
  end

  # GET /account/bots — список ботов с curl-командами по комнатам
  # (bots.eta: заголовок с bot+add, аватары, pencil-edit, поля с
  # иконками messages-outlined/attachment и copy-кнопками).
  def index
    bots = User.where("role = 2 AND status = 0").order("lower(name)").to_a
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.page_open("bots", "Chat bots", current_user.not_nil!,
        body_class: "bots",
        nav_html: ChatLayout.nav_back("/account/edit"))
      io << %(<section class="panel panel--wide txt-align-center flex flex-column position-relative" )
      io << %(style="view-transition-name: chat-bots"><div class="flex align-center gap">)
      io << %(<div class="panel__button">Chat bots</div><div class="pad-inline-double center">)
      io << %(<h1 class="margin-none">Chat bots</h1>)
      io << %(<p class="margin-none-block-start">With Chat bots, other sites and services can post updates directly to Campfire.</p>)
      io << %(<a href="/account/bots/new" class="btn btn--reversed txt-large" aria-label="Add a chat bot">)
      io << ChatLayout.icon("bot.svg") << ChatLayout.icon("add.svg")
      io << %(</a></div></div>\n)
      io << %(<div class="pad-inline pad-block-start"><menu class="flex flex-column gap margin-none pad">\n)
      bots.each do |bot|
        bid = bot.id.not_nil!
        io << %(<li class="flex flex-column gap flush fill-shade border-radius pad-block pad-inline-double">)
        io << %(<div class="flex align-center gap">)
        io << %(<figure class="avatar flex-item-no-shrink" style="--avatar-size: 2.65em;">)
        io << %(<a title=") << HTML.escape(bot.name.to_s)
        io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/) << bid << %(">)
        io << %(<img src="/users/) << bid << %(/avatar" aria-hidden="true" width="48" height="48"></a></figure>)
        io << %(<div class="min-width"><div class="overflow-ellipsis txt-large"><strong>)
        io << HTML.escape(bot.name.to_s) << %(</strong></div></div>)
        io << %(<a href="/account/bots/) << bid << %(/edit" class="btn flex-item-justify-end" )
        io << %(style="view-transition-name: chat-bot-) << bid << %(">)
        io << ChatLayout.icon("pencil.svg")
        io << %(<span class="for-screen-reader">Edit ) << HTML.escape(bot.name.to_s) << %(</span></a></div>\n)
        # _bot.html.erb: bot.rooms.without_directs.ordered — без Direct
        # (сид: 'Rooms::Direct', наши: 'Direct'), по LOWER(name).
        Room.visible_for(bot)
          .where("rooms.type NOT IN ('Rooms::Direct', 'Direct')")
          .order("lower(name)").each do |room|
          bot_key = "#{bid}-#{bot.bot_token.to_s}"
          text = "curl -d 'Hello!' #{origin}/rooms/#{room.id.not_nil!}/#{bot_key}/messages"
          upload = "curl -F 'file=@yourfile' #{origin}/rooms/#{room.id.not_nil!}/#{bot_key}/messages"
          io << %(<fieldset class="gap max-width pad border border-radius">)
          io << %(<legend class="min-width txt-align-start pad-inline"><strong class="overflow-ellipsis">)
          io << HTML.escape(room.name.to_s) << %(</strong></legend>\n)
          [{text, "posting messages", "messages-outlined.svg", "Copy message command"},
           {upload, "posting attachments", "attachment.svg", "Copy attachment command"}].each do |cmd, label, icn, sr|
            io << %(<div class="flex align-center gap">)
            io << ChatLayout.icon(icn, 24, "colorize--black")
            io << %(<div class="flex-item-grow"><input type="text" class="input full-width fill-white" value=")
            io << HTML.escape(cmd) << %(" aria-label="curl command for ) << label << %(" readonly></div>)
            io << %(<div class="txt-small">) << ChatLayout.copy_button(cmd, sr) << %(</div></div>\n)
          end
          io << %(</fieldset>\n)
        end
        io << %(</li>\n)
      end
      io << %(</menu></div></section>\n)
      io << ChatLayout.page_close
    end)
  end

  # GET /account/bots/:id/edit — форма с текущим именем.
  def edit
    bot = User.where("id = ? AND role = 2 AND status = 0",
      params["id"].to_s.to_i64).take
    return head(:not_found) unless bot
    render(html: String.build { |io| bot_form(io, bot) })
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
    redirect_to "/account/bots"
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
    redirect_to "/account/bots"
  end

  # bot_form.eta: nav-назад к списку ботов, аватар бота (default-bot),
  # поля с иконками bot/web, save с check, delete/key-панель.
  private def bot_form(io, bot : User?) : Nil
    io << ChatLayout.page_open("bot-form", bot ? "Edit chat bot" : "New chat bot",
      current_user.not_nil!, body_class: "bot-form",
      nav_html: ChatLayout.nav_back("/account/bots"))
    io << %(<section class="panel">)
    action = bot ? "/account/bots/#{bot.id.not_nil!}" : "/account/bots"
    io << %(<form action=") << action << %(" accept-charset="UTF-8" method="post" )
    io << %(class="flex flex-column gap">)
    io << %(<input type="hidden" name="_method" value="patch">) if bot
    io << %(<h1 class="for-screen-reader">Chat Bot Setup</h1>\n)
    io << %(<label class="align-center center avatar__form gap">)
    io << %(<div class="avatar input--file txt-xx-large" style="--avatar-size: var(--btn-size);">)
    io << %(<img src=") << ChatLayout.asset("default-bot-avatar.svg")
    io << %(" alt="Bot avatar" width="48" height="48"></div></label>\n)
    io << %(<div class="flex align-center gap">)
    io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
    io << %(<input type="text" name="user[name]" id="user_name" value=")
    io << HTML.escape(bot.try(&.name).to_s)
    io << %(" class="input" autocomplete="name" placeholder="Name the bot" )
    io << %(autofocus required data-1p-ignore="true">)
    io << ChatLayout.icon("bot.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<div class="flex align-center gap">)
    io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
    io << %(<input type="url" name="user[webhook_url]" id="user_webhook_url" value=")
    io << HTML.escape(bot.try(&.webhook_url).to_s)
    io << %(" class="input" placeholder="Webhook URL">)
    io << ChatLayout.icon("web.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<button class="btn btn--reversed center txt-large" type="submit">)
    io << ChatLayout.icon("check.svg")
    io << %(<span class="for-screen-reader">Save changes</span></button>\n)
    io << %(</form>\n)
    if bot
      bid = bot.id.not_nil!
      io << %(<hr class="separator full-width margin-block-double">)
      io << %(<div class="flex align-center gap justify-space-between">)
      io << %(<form action="/account/bots/) << bid << %(" method="post">)
      io << %(<input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn txt--small btn--negative" aria-label="Delete this chat bot" )
      io << %(data-turbo-confirm="Are you sure you want to permanently remove this bot from the account? This can’t be undone.">)
      io << ChatLayout.icon("trash.svg") << ChatLayout.icon("bot.svg") << %(</button></form>\n)
      io << %(</div>\n)
    end
    io << %(</section>\n)
    io << ChatLayout.page_close
  end

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

  private def require_admin : Nil
    unless current_user.not_nil!.role == 1
      render(plain: "forbidden", status: 403)
    end
  end
end
