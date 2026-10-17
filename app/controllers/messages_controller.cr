require "uuid"

# GET /rooms/:id/messages?before=<anchor_id> — страница истории
# (контракт: 40 сообщений STRICTLY BEFORE anchor по created_at, вывод ASC).
# POST /rooms/:id/messages — создание сообщения (контракт: turbo-stream
# append; аудит: messages + action_text_rich_texts + FTS5 с телом).
class MessagesController < ApplicationController
  skip_before_action :require_authentication, only: [:bot_create, :bot_index, :bot_show]

  # jbuilder-вьюхи bots-API (bot_index/bot_show)
  @messages : Array(Message) = [] of Message
  @message : Message?

  def index
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!
    user = current_user.not_nil!

    # Whole-page response cache (как rooms#show): ключ включает query
    # (?before=...), инвалидация — общий DB-epoch.
    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key("messages#index", request, user.id)
    if (cached = PageCache.get(key, epoch))
      return send_page(cached)
    end

    anchor = params["before"]?
    after_anchor = params["after"]?
    messages = if anchor && (anchor_id = anchor.to_s.to_i64?)
      Message.where(
        "room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, anchor_id)
        .order("created_at DESC").limit(40).to_a.reverse
    elsif after_anchor && (after_id = after_anchor.to_s.to_i64?)
      Message.where(
        "room_id = ? AND created_at > (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, after_id)
        .order("created_at ASC").limit(40).to_a
    else
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
    end

    # Rails messages#index: пустая страница → 204 No Content (пагинатор
    # по нему понимает, что история дочитана).
    if messages.empty?
      response.status = :no_content
      return render(plain: "")
    end

    page = Campfire::PageCache::Page.new(messages_page_html(room, messages, epoch))
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end

  def create
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    user = current_user.not_nil!

    body_html = message_body_param
    client_message_id = message_client_id_param || UUID.random.to_s
    upload : MessageCreator::UploadedFile? = nil
    if form = parse_multipart_form
      if (item = form["message[attachment]"]?).is_a?(MessageCreator::UploadedFile)
        upload = item
      end
      if (cmid = form["message[client_message_id]"]?).is_a?(String) && !cmid.empty?
        client_message_id = cmid
      end
      if (text = form["message[body]"]?).is_a?(String) && !text.empty?
        body_html = text
      end
    end

    # Вставка + ActionText-тело + FTS5-индекс + broadcast + unread +
    # джобы уведомлений (push/webhook) в очередь — persisted до ответа
    # (аудит validate_acks требует первые три с точным телом).
    # attachment: файл → blob + active_storage_attachments (storage.js).
    message = MessageCreator.create!(room, user, body_html, client_message_id,
      attachment: upload, base_url: origin)

    attachment = upload ? ChatLayout.attachments_for([message.id.not_nil!])[message.id.not_nil!]? : nil
    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_#{room.dom_id}"><template>)
      io << ChatLayout.message_dom(message, room, user, attachment, base_url: origin)
      io << %(</template></turbo-stream>\n)
    end

    render(html: turbo_frame, content_type: "text/vnd.turbo-stream.html")
  end

  # GET /rooms/:id/:bot_key/messages — JSON-API бота (by_bots index
  # референса + routes.js): страница истории (before/after по anchor-
  # сообщению, 40 шт, вывод ASC), заголовки X-Total-Count/Link.
  # Разметка — messages/bot_index.json.jbuilder (+ _message/_user).
  def bot_index
    bot = bot_from_key
    unless bot
      return render(plain: "Unauthorized", status: :unauthorized)
    end
    room = bot_room(bot)
    unless room
      return render(plain: "Not Found", status: :not_found)
    end
    room = room.not_nil!

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
    render(template: "messages/bot_index")
  end

  # GET /rooms/:id/:bot_key/messages/:message_id — JSON-API бота
  # (by_bots show): одно сообщение. Разметка — messages/bot_show.json.jbuilder.
  def bot_show
    bot = bot_from_key
    unless bot
      return render(plain: "Unauthorized", status: :unauthorized)
    end
    room = bot_room(bot)
    message = Message.find?(params["message_id"].to_s.to_i64)
    unless message && room && message.room_id == room.id.not_nil!
      return render(plain: "Not Found", status: :not_found)
    end
    @message = message.not_nil!
    render(template: "messages/bot_show")
  end

  # POST /rooms/:id/:bot_key/messages — публикация от имени бота
  # (routes.js: botKey = "<id>-<bot_token>", plain body). Аутентификация
  # по боту, не по сессии.
  def bot_create
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    bot_key = params["bot_key"].to_s
    dash = bot_key.index('-')
    return render(plain: "invalid bot key", status: 404) unless dash
    bot_id = bot_key[0, dash].to_i64?
    token = bot_key[(dash + 1)..]
    bot = bot_id && User.where(
      "id = ? AND bot_token = ? AND role = 2 AND status = 0", bot_id, token).take
    return render(plain: "invalid bot key", status: 404) unless bot

    plain = request.body.try(&.gets_to_end).to_s
    body_html = "<p>#{HTML.escape(plain)}</p>"
    client_message_id = UUID.random.to_s

    message = MessageCreator.create!(room, bot, body_html, client_message_id,
      base_url: origin)

    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_#{room.dom_id}"><template>)
      io << ChatLayout.message_dom(message, room, bot, base_url: origin)
      io << %(</template></turbo-stream>\n)
    end
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      turbo_frame)
    render(html: turbo_frame, content_type: "text/vnd.turbo-stream.html")
  end

  # botUser(req) эталона: "<id>-<token>" → User (role=2, активный).
  private def bot_from_key : User?
    bot_key = params["bot_key"].to_s
    dash = bot_key.index('-')
    if dash && (bot_id = bot_key[0, dash].to_i64?)
      User.where(
        "id = ? AND bot_token = ? AND role = 2 AND status = 0",
        bot_id, bot_key[(dash + 1)..]).take
    end
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

  # show.html.erb (render @message): страница с DOM сообщения. Turbo
  # извлекает из ответа фрейм edit_message_<id> — это завершает навигацию
  # фрейма после редиректа update (фрейм получает [complete]) и
  # подтягивает отрендеренное сообщение.
  # show.html.erb / edit.html.erb
  @room : Room?
  @message : Message?
  @mid : Int64?
  @attachment : ChatLayout::Attachment?

  def show
    room = Room.find?(params["id"].to_s.to_i64)
    message = Message.find?(params["message_id"].to_s.to_i64)
    unless room && message && message.room_id == room.id
      response.status = :not_found
      return render(plain: "Message not found")
    end
    @room = room
    @message = message
  end

  # GET /rooms/:id/messages/:message_id/edit — форма редактирования в
  # turbo-frame edit_message_<id> (edit.html.erb).
  def edit
    room = Room.find?(params["id"].to_s.to_i64)
    message = Message.find?(params["message_id"].to_s.to_i64)
    user = current_user.not_nil!
    unless room && message && message.room_id == room.id
      response.status = :not_found
      return render(plain: "Message not found")
    end
    room = room.not_nil!
    message = message.not_nil!
    if message.creator_id != user.id && user.role != 1
      response.status = :forbidden
      return render(plain: "Cannot edit this message")
    end

    @room = room
    @message = message
    @mid = message.id.not_nil!
    @attachment = ChatLayout.attachments_for([@mid.not_nil!])[@mid.not_nil!]?
  end

  # DELETE /rooms/:id/messages/:message_id — удаление сообщения
  # (edit_message.eta: turbo-stream remove + инвалидация кэшей).
  def destroy
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    room = Room.find?(params["id"].to_s.to_i64)
    message = Message.find?(params["message_id"].to_s.to_i64)
    user = current_user.not_nil!
    unless room && message && message.room_id == room.id
      response.status = :not_found
      return render(plain: "Message not found")
    end
    if message.creator_id != user.id
      response.status = :forbidden
      return render(plain: "Cannot delete this message")
    end

    mid = message.id.not_nil!
    ActiveRecord::Base.connection.exec(
      "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
    ActiveRecord::Base.connection.exec(
      "DELETE FROM message_search_index WHERE rowid=?", mid)
    message.destroy

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша

    stream = String.build do |io|
      io << %(<turbo-stream action="remove" target="message_#{mid}"></turbo-stream>\n)
    end
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]), stream)
    render(html: stream, content_type: "text/vnd.turbo-stream.html")
  end

  # PATCH /rooms/:id/messages/:message_id — обновление тела: rich text,
  # FTS5-индекс, updated_at (messages_controller.rb#update): broadcast
  # turbo-stream replace presentation-дива (maintain_scroll, как Rails
  # attributes: { maintain_scroll: true }), HTTP-ответ — редирект на
  # message show; Turbo проводит редирект внутри edit-фрейма и
  # перерисовывает сообщение (фрейм становится complete).
  def update
    room = Room.find?(params["id"].to_s.to_i64)
    message = Message.find?(params["message_id"].to_s.to_i64)
    user = current_user.not_nil!
    unless room && message && message.room_id == room.id
      response.status = :not_found
      return render(plain: "Message not found")
    end
    if message.creator_id != user.id
      response.status = :forbidden
      return render(plain: "Cannot edit this message")
    end

    Campfire::PageCache.invalidate! # write: сброс whole-page кэша

    body_html = message_body_param
    plain = plain_text(body_html)
    now = Time.utc
    # Отдельная локальная переменная: message не должен захватываться
    # замыканием очереди (иначе компилятор теряет Nil-narrowing выше).
    target = message
    Campfire::WriteQueue.perform do
      conn = ActiveRecord::Base.connection
      conn.exec(
        "UPDATE action_text_rich_texts SET body = ?, updated_at = ? WHERE record_type = 'Message' AND record_id = ?",
        body_html.empty? ? plain : body_html, now, target.not_nil!.id.not_nil!)
      conn.exec(
        "DELETE FROM message_search_index WHERE rowid = ?", target.not_nil!.id.not_nil!)
      conn.exec(
        "INSERT INTO message_search_index (rowid, body) VALUES (?, ?)",
        target.not_nil!.id.not_nil!, plain)
      conn.exec("UPDATE messages SET updated_at = ? WHERE id = ?", now, target.not_nil!.id.not_nil!)
    end

    message = Message.find?(message.id.not_nil!).not_nil!
    mid = message.id.not_nil!
    presentation = ChatLayout.presentation_dom(mid, ChatLayout.text_presentation(message.body.to_s))
    stream = %(<turbo-stream action="replace" target="presentation_message_#{mid}" maintain_scroll="true"><template>) +
      presentation + %(</template></turbo-stream>\n)
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      stream)
    redirect_to "/rooms/#{room.id.not_nil!}/messages/#{mid}"
  end

  private def message_body_param : String
    nested = params["message"]?
    value = case nested
            when ActionController::Parameters then nested["body"]?
            else nested ? nested : nil
            end
    # loadgen шлёт form-encoded message[body] (HTML от trix) или plain text
    value.to_s
  end

  # multipart/form-data от file_uploader.js: файл идёт напрямую в POST
  # сообщения (message[attachment] + message[client_message_id]), без
  # ActiveStorage direct uploads. action_pack_cr парсит только json и
  # form-urlencoded, поэтому multipart разбираем здесь: поля без
  # filename — строки, с filename — UploadedFile (байты + content-type).
  private def parse_multipart_form : Hash(String, String | MessageCreator::UploadedFile)?
    content_type = request.headers["Content-Type"]?
    return nil unless content_type.try(&.includes?("multipart/form-data"))
    match = content_type.not_nil!.match(/boundary=([^";]+)/)
    return nil unless match
    boundary = match[1].strip('"')

    raw = request.body.try(&.gets_to_end).to_s
    return nil if raw.empty?
    delimiter = "--" + boundary
    start = raw.index(delimiter)
    return nil unless start
    rest = raw[(start + delimiter.size)..]

    form = {} of String => String | MessageCreator::UploadedFile
    rest.split("\r\n" + delimiter).each do |piece|
      next if piece.starts_with?("--") # закрывающий --boundary--
      piece = piece[2..] if piece.starts_with?("\r\n")
      sep = piece.index("\r\n\r\n")
      next unless sep
      headers = piece[0...sep]
      content = piece[(sep + 4)..]
      name = headers[/name="([^"]*)"/, 1]?
      next unless name
      if (filename = headers[/filename="([^"]*)"/, 1]?) && !filename.empty?
        ctype = headers[/content-type:\s*([^\r\n]+)/i, 1]?.try(&.strip) ||
                "application/octet-stream"
        form[name] = MessageCreator::UploadedFile.new(filename, ctype, content.to_slice)
      else
        form[name] = content
      end
    end
    form
  end

  private def message_client_id_param : String?
    nested = params["message"]?
    case nested
    when ActionController::Parameters
      v = nested["client_message_id"]?
      v.nil? || v.to_s.empty? ? nil : v.to_s
    else
      nil
    end
  end

  # Грубое html→text для FTS5-индекса: контракту достаточно вхождения
  # слов тела; теги вырезаем.
  private def plain_text(html : String) : String
    html.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
  end

  # ————— ERB-хелперы (app/views/messages/{show,edit}.html.erb) —————

  # show.html.erb: DOM сообщения (тот же message_dom, что в комнате).
  private def message_dom : ERB::SafeString
    message = @message.not_nil!
    attachment = ChatLayout.attachments_for([message.id.not_nil!])[message.id.not_nil!]?
    ERB::SafeString.new(ChatLayout.message_dom(message, @room.not_nil!,
      User.find?(message.creator_id.not_nil!), attachment, base_url: origin))
  end

  # edit.html.erb: presentation вложения (attachment-ветка).
  private def attachment_html : ERB::SafeString
    ERB::SafeString.new(ChatLayout.attachment_presentation(@attachment.not_nil!))
  end

  # /rooms/:id/messages/:message_id для экшена.
  private def message_path : String
    "/rooms/#{@room.not_nil!.id}/messages/#{@mid}"
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  # messages.eta (референс): каждая запись — тот же DOM, что в комнате
  # (message_dom: <div data-message-id=...> + turbo-frame + </turbo-frame>
  # </div> closure); минимальный <article> не проходит route-contract-v1
  # loadgen'а (<div ... data-message-id> + </turbo-frame></div>$).
  # Список — через fragment-кэш (было User.find?/rich_text на каждое
  # сообщение): хиты без SQL, авторы промахов — одним IN-запросом.
  # Rails messages/index.html.erb (layout false): голая коллекция
  # message-партиалов — без doctype/обёрток; JS-пагинатор вставляет
  # ответ как фрагмент прямо в .messages.
  private def messages_page_html(room : Room, messages : Array(Message),
                                 epoch : String) : String
    String.build do |io|
      ChatLayout.messages_to(io, messages, epoch, room, origin)
    end
  end
end
