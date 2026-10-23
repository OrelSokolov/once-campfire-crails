require "uuid"

# Bot-API: /rooms/:id/:bot_key/messages — JSON-API бота (референс:
# messages/by_bots_controller.rb + routes.js). Аутентификация по
# "<id>-<bot_token>" в пути, не по сессии.
class Messages::ByBotsController < ApplicationController
  include RawRequestBody
  include MessagesHelper

  skip_before_action :require_authentication

  before_action :require_bot, except: [:create]
  before_action :set_room, only: [:index, :show, :update, :destroy]
  before_action :set_message, only: [:update, :destroy]
  before_action :ensure_can_administer, only: [:update, :destroy]

  # jbuilder-вьюхи bots-API (index/show)
  @messages : Array(Message) = [] of Message
  @message : Message?
  @room : Room?

  # GET /rooms/:id/:bot_key/messages — by_bots index референса: страница
  # истории (before/after по anchor-сообщению, 40 шт, вывод ASC), заголовки
  # X-Total-Count/Link. Разметка — messages/by_bots/index.json.jbuilder
  # (+ _message/_user партиалы).
  def index
    room = @room.not_nil!

    @messages = bot_messages_page(room)
    return if @performed # anchor вне комнаты → уже отрендерен 404
    if @messages.empty?
      return render(plain: "", status: :no_content)
    end

    # X-Total-Count + Link rel=next (routes.js: direction = after?after:before,
    # anchor — последний (after) / первый элемент, «за ним» есть сообщения).
    conn = ActiveRecord::Base.connection
    total = conn.query_one(
      "SELECT count(*) FROM messages WHERE room_id = ?", room.id.not_nil!,
      as: Int64)
    response.headers["X-Total-Count"] = total.to_s
    direction = params["after"]? ? "after" : "before"
    anchor = direction == "after" ? @messages.last : @messages.first
    if (anchor_id = anchor.try(&.id))
      op = direction == "after" ? ">" : "<"
      has_next = conn.query_one?(
        "SELECT id FROM messages WHERE room_id = ? AND created_at #{op} " \
        "(SELECT created_at FROM messages WHERE id = ?) LIMIT 1",
        room.id.not_nil!, anchor_id, as: Int64)
      if has_next
        response.headers["Link"] =
          %(<#{origin}/rooms/#{room.id.not_nil!}/#{params["bot_key"]}/messages?#{direction}=#{anchor_id}>; rel="next")
      end
    end
    render(template: "messages/by_bots/index")
  end

  # GET /rooms/:id/:bot_key/messages/:message_id — by_bots show: одно
  # сообщение. Разметка — messages/by_bots/show.json.jbuilder.
  def show
    render(template: "messages/by_bots/show")
  end

  # POST /rooms/:id/:bot_key/messages — публикация от имени бота
  # (routes.js: botKey = "<id>-<bot_token>", plain body). Аутентификация
  # по боту, не по сессии.
  def create
    return head(:payload_too_large) if upload_too_large?
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!
    bot = bot_from_key
    return render(plain: "invalid bot key", status: 404) unless bot

    plain = raw_request_body
    # Rails message_params бота: body = raw_request_body — ActionText
    # хранит plain-строку как есть, презентация рендерит текст без <p>.
    body_html = HTML.escape(plain)
    client_message_id = UUID.random.to_s

    message = MessageCreator.create!(room, bot, body_html, client_message_id,
      base_url: origin)

    # broadcast_create референса выполняется внутри MessageCreator.create!
    # (один append в [room, :messages], как MessagesController#create →
    # super у Rails); HTTP-ответ — create.turbo_stream.erb-аналог (тег + \n),
    # html без хвостового \n — render_to_string партиала у Rails кончается
    # ровно </div> (Erubi глотает переводы после <% end %>).
    message_html = ChatLayout.message_dom(message, room, bot, base_url: origin).chomp
    render(html: append_message_stream(room, message_html),
      content_type: "text/vnd.turbo-stream.html")
  end

  # PATCH/PUT /rooms/:id/:bot_key/messages/:message_id — правка своего
  # сообщения ботом (by_bots update: message_params = raw body,
  # ensure_can_administer — создатель или админ). Тело — ActionText +
  # FTS5 + touch, broadcast replace presentation (maintain_scroll);
  # ответ — bot_show JSON (format :json роута).
  def update
    bot = bot_from_key.not_nil!
    room = @room.not_nil!
    message = @message.not_nil!

    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша

    # by_bots message_params: body = raw_request_body — ActionText
    # хранит plain-строку с escape (как в bot_create).
    plain = raw_request_body
    body_html = HTML.escape(plain)
    now = Time.utc
    target = message
    Campfire::WriteQueue.perform do
      conn = ActiveRecord::Base.connection
      conn.exec(
        "UPDATE action_text_rich_texts SET body = ?, updated_at = ? WHERE record_type = 'Message' AND record_id = ?",
        body_html, now, target.not_nil!.id.not_nil!)
      Message::Searchable.update_in_index(conn, target.not_nil!.id.not_nil!, plain)
      # touch сообщения (аналог AR updated_at при update!)
      target.not_nil!.touch
    end

    mid = target.not_nil!.id.not_nil!
    message = Message.find?(mid).not_nil!
    # by_bots update наследует MessagesController#update: broadcast_replace
    # presentation (maintain_scroll, attributes — через broadcast_action_to).
    broadcast_action_to([room, "messages"], :replace,
      target: "presentation_message_#{mid}",
      html: ChatLayout.presentation_dom(mid, ChatLayout.text_presentation(message.body.to_s)),
      attributes: {"maintain_scroll" => "true"})
    @message = message
    render(template: "messages/by_bots/show")
  end

  # DELETE /rooms/:id/:bot_key/messages/:message_id — удаление своего
  # сообщения ботом (by_bots destroy: super — broadcast_remove, затем
  # head :no_content; ensure_can_administer — создатель или админ).
  def destroy
    room = @room.not_nil!
    message = @message.not_nil!

    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша
    mid = message.id.not_nil!
    ActiveRecord::Base.connection.exec(
      "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
    Message::Searchable.remove_from_index(ActiveRecord::Base.connection, mid)
    message.destroy

    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша

    broadcast_remove_to([room, "messages"], target: "message_#{mid}")
    head(:no_content)
  end

  private def require_bot
    render(plain: "Unauthorized", status: :unauthorized) unless bot_from_key
  end

  # Лимит тела бот-запроса (как в MessagesController): raw body читается
  # в память целиком.
  MAX_UPLOAD_BYTES = MessagesController::MAX_UPLOAD_BYTES

  private def upload_too_large? : Bool
    if (length = request.headers["Content-Length"]?.try(&.to_i64?)) &&
       length > MAX_UPLOAD_BYTES
      return true
    end
    false
  end

  # by_bots set_room: комната + membership бота (roomForUser эталона).
  private def set_room
    if room = bot_room(bot_from_key.not_nil!)
      @room = room
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  private def set_message
    if (message = Message.find?(params["message_id"].to_s.to_i64)) &&
       message.room_id == @room.try(&.id)
      @message = message
    else
      render(plain: "Not Found", status: :not_found)
    end
  end

  # ensure_can_administer (наследуется из MessagesController у референса):
  # создатель или админ.
  private def ensure_can_administer
    head :forbidden unless bot_from_key.not_nil!.can_administer?(@message)
  end

  # botUser(req) эталона: "<id>-<token>" → User (role=2, активный).
  # Сравнение токена — User.authenticate_bot (constant-time).
  private def bot_from_key : User?
    User.authenticate_bot(params["bot_key"].to_s)
  end

  # roomForUser(bot, id) эталона: комната с membership бота.
  private def bot_room(bot : User) : Room?
    room = Room.find?(params["id"].to_s.to_i64)
    return nil unless room
    member = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, bot.id.not_nil!).take
    member ? room : nil
  end

  # messagesForRoom эталона: before → 40 строго до anchor (вывод ASC),
  # after → 40 строго после (ASC, без reverse), без anchor — последние 40
  # ASC. Anchor вне комнаты → 404 (pivot-запрос эталона).
  private def bot_messages_page(room : Room) : Array(Message)
    room_id = room.id.not_nil!
    anchor = params["before"]?
    after_anchor = params["after"]?
    if (anchor_id = anchor.try(&.to_s.to_i64?)) || (anchor_id = after_anchor.try(&.to_s.to_i64?))
      pivot = ActiveRecord::Base.connection.query_one?(
        "SELECT created_at FROM messages WHERE id = ? AND room_id = ?",
        anchor_id.not_nil!, room_id, as: Time)
      unless pivot
        render(plain: "Not Found", status: :not_found)
        return [] of Message
      end
      op = after_anchor ? ">" : "<"
      ordering = after_anchor ? "ASC" : "DESC"
      # Time биндим только через подзапрос: прямое связывание даёт
      # RFC3339-строку, а колонка — "YYYY-MM-DD HH:MM:SS(.mmm)" —
      # строковое сравнение расходится (см. messages#index).
      rows = Message.where(
        "room_id = ? AND created_at #{op} (SELECT created_at FROM messages WHERE id = ?)",
        room_id, anchor_id.not_nil!)
        .order("created_at #{ordering}").limit(40).to_a
      after_anchor ? rows : rows.reverse
    else
      Message.where("room_id = ?", room_id)
        .order("created_at DESC").limit(40).to_a.reverse
    end
  end
end
