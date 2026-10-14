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
    # createUser эталона (domain.js): новый пользователь (включая бота)
    # получает membership во все Rooms::Open (involvement "mentions").
    # STI-порт хранит type коротким именем подкласса ("Open").
    Room.where("type = 'Open'").each do |room|
      Membership.new(room_id: room.id.not_nil!, user_id: bot.id.not_nil!,
        involvement: "mentions", connections: 0,
        created_at: now, updated_at: now).save!
    end
    redirect_to "/account/bots"
  end

  # GET /account/bots — список ботов с curl-командами по комнатам
  # (bots.eta: botCommand = `curl -d 'Hello!' <origin>/rooms/<id>/<key>/messages`).
  def index
    bots = User.where("role = 2 AND status = 0").order("lower(name)").to_a
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.head("Chat bots", current_user.not_nil!, nil, chat: false)
      io << %(<body>\n<main id="main-content">\n)
      bots.each do |bot|
        io << %(<section class="panel">\n<h2>) << HTML.escape(bot.name.to_s) << %(</h2>\n)
        io << %(<a href="/account/bots/) << bot.id.not_nil!.to_s << %(/edit">Edit )
        io << HTML.escape(bot.name.to_s) << %(</a>\n)
        Room.visible_for(bot).order("id").each do |room|
          bot_key = "#{bot.id.not_nil!}-#{bot.bot_token.to_s}"
          command = "curl -d 'Hello!' #{origin}/rooms/#{room.id.not_nil!}/#{bot_key}/messages"
          io << %(<fieldset class="gap max-width pad border border-radius">\n)
          io << %(<legend><strong>) << HTML.escape(room.name.to_s) << %(</strong></legend>\n)
          io << %(<input type="text" class="input full-width fill-white" value=")
          io << HTML.escape(command)
          io << %(" aria-label="curl command for posting messages" readonly>\n)
          io << %(</fieldset>\n)
        end
        io << %(</section>\n)
      end
      io << %(</main>\n</body>\n</html>\n)
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
    bot = User.where("id = ? AND role = 2 AND status = 0",
      params["id"].to_s.to_i64).take
    return head(:not_found) unless bot
    name = nested("name")
    bot.name = name unless name.empty?
    bot.updated_at = Time.utc
    bot.save!
    redirect_to "/account/bots"
  end

  private def bot_form(io, bot : User?) : Nil
    io << ChatLayout.head(bot ? "Edit chat bot" : "New chat bot",
      current_user.not_nil!, nil, chat: false)
    io << %(<body>\n<main id="main-content">\n)
    io << %(<section class="panel">)
    action = bot ? "/account/bots/#{bot.id.not_nil!}" : "/account/bots"
    io << %(<form action=") << action << %(" accept-charset="UTF-8" method="post" )
    io << %(class="flex flex-column gap">)
    io << %(<input type="hidden" name="_method" value="patch">) if bot
    io << %(<h1 class="for-screen-reader">Chat Bot Setup</h1>\n)
    io << %(<div class="flex align-center gap">)
    io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
    io << %(<input type="text" name="user[name]" id="user_name" value=")
    io << HTML.escape(bot.try(&.name).to_s)
    io << %(" class="input" autocomplete="name" placeholder="Name the bot" )
    io << %(autofocus required data-1p-ignore="true"></label></div>\n)
    io << %(<div class="flex align-center gap">)
    io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
    io << %(<input type="url" name="user[webhook_url]" id="user_webhook_url" value="" )
    io << %(class="input" placeholder="Webhook URL"></label></div>\n)
    io << %(<button class="btn btn--reversed center txt-large" type="submit">)
    io << %(<span class="for-screen-reader">Save changes</span></button>\n)
    io << %(</form></section>\n</main>\n</body>\n</html>\n)
  end

  private def nested(key : String) : String
    nested = params["user"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    nested[key]?.to_s
  end

  private def require_admin : Nil
    unless current_user.not_nil!.role == 1
      render(plain: "forbidden", status: 403)
    end
  end
end
