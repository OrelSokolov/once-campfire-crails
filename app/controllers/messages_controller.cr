require "uuid"

# GET /rooms/:id/messages?before=<anchor_id> — страница истории
# (контракт: 40 сообщений STRICTLY BEFORE anchor по created_at, вывод ASC).
# POST /rooms/:id/messages — создание сообщения (контракт: turbo-stream
# append; аудит: messages + action_text_rich_texts + FTS5 с телом).
class MessagesController < ApplicationController
  skip_before_action :require_authentication, only: :bot_create

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
    messages = if anchor && (anchor_id = anchor.to_s.to_i64?)
      Message.where(
        "room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, anchor_id)
        .order("created_at DESC").limit(40).to_a.reverse
    else
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
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

    # Вставка + ActionText-тело + FTS5-индекс + broadcast + unread +
    # джобы уведомлений (push/webhook) в очередь — persisted до ответа
    # (аудит validate_acks требует первые три с точным телом).
    message = MessageCreator.create!(room, user, body_html, client_message_id)

    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_room_#{room.id}"><template>)
      io << ChatLayout.message_dom(message, room, user)
      io << %(</template></turbo-stream>\n)
    end

    render(html: turbo_frame, content_type: "text/vnd.turbo-stream.html")
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

    message = MessageCreator.create!(room, bot, body_html, client_message_id)

    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_room_#{room.id}"><template>)
      io << ChatLayout.message_dom(message, room, bot)
      io << %(</template></turbo-stream>\n)
    end
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      turbo_frame)
    render(html: turbo_frame, content_type: "text/vnd.turbo-stream.html")
  end
  # GET /rooms/:id/messages/:message_id/edit — форма редактирования в
  # turbo-frame edit_message_<cid> (edit_message.eta).
  def edit
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

    cid = message.client_message_id.to_s.presence || message.id.to_s
    body = message.body.to_s
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << %(<turbo-frame id="edit_message_#{cid}">\n)
      io << %(<div class="message__body position-relative" data-controller="scroll-into-view">\n)
      io << %(<div class="message__body-content message__body-content--editing gap">\n)
      io << %(<div class="composer--edit composer--rich-text">\n)
      io << %(<form id="form_message_#{cid}" data-controller="form" )
      io << %(data-action="keydown.esc-&gt;form#cancel keydown.ctrl+enter-&gt;form#submit:prevent keydown.meta+enter-&gt;form#submit:prevent" )
      io << %(action="/rooms/#{room.id}/messages/#{message.id}" accept-charset="UTF-8" method="post">)
      io << %(<input type="hidden" name="_method" value="patch">\n)
      io << %(<div class="full-width input input--actor min-width fill-white">)
      io << %(<lexxy-editor rows="1" class="input lexxy-content" aria-multiline="true" aria-label="Edit message" autofocus="autofocus" )
      io << %(id="message_body" name="message[body]" value=") << HTML.escape(body) << %(">)
      io << %(</lexxy-editor>\n</div>\n)
      io << %(<div class="message__edit-btns flex align-center justify-space-between gap full-width pad-block-start-half">)
      io << %(<button name="button" type="submit" class="btn btn--reversed">)
      io << %(<span class="for-screen-reader">Save changes</span></button>\n)
      io << %(</div>\n</form>\n</div>\n</div>\n)
      io << %(<div class="message__actions flex flex-wrap">)
      io << %(<a class="message__action-btn message__edit-close-btn txt-small btn btn--borderless" href="/rooms/#{room.id}">)
      io << %(<span class="for-screen-reader">Close editor and discard changes</span></a></div>\n)
      io << %(</div>\n</turbo-frame>\n)
    end)
  end

  # PATCH /rooms/:id/messages/:message_id — обновление тела: rich text,
  # FTS5-индекс, updated_at; ответ и broadcast — turbo-stream replace
  # message_<cid> (publishMessage(message, "replace") у express).
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
    cid = message.client_message_id.to_s.presence || message.id.to_s
    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="replace" target="message_#{cid}"><template>)
      io << ChatLayout.message_dom(message, room, user)
      io << %(</template></turbo-stream>\n)
    end
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      turbo_frame)
    render(html: turbo_frame, content_type: "text/vnd.turbo-stream.html")
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

  # messages.eta (референс): каждая запись — тот же DOM, что в комнате
  # (message_dom: <div data-message-id=...> + turbo-frame + </turbo-frame>
  # </div> closure); минимальный <article> не проходит route-contract-v1
  # loadgen'а (<div ... data-message-id> + </turbo-frame></div>$).
  # Список — через fragment-кэш (было User.find?/rich_text на каждое
  # сообщение): хиты без SQL, авторы промахов — одним IN-запросом.
  private def messages_page_html(room : Room, messages : Array(Message),
                                 epoch : String) : String
    String.build do |io|
      io << "<!doctype html>\n<html>\n<head><title>"
      io << HTML.escape(room.name.to_s)
      io << "</title></head>\n<body>\n"
      io << %(<main id="messages_room_#{room.id}">\n)
      ChatLayout.messages_to(io, messages, epoch, room)
      # Без закрывающих </main></body></html>: route-contract-v1 требует,
      # чтобы сегмент последнего сообщения заканчивался ровно на
      # "</turbo-frame></div>" (closure); messages_page — partial-ответ
      # истории (подгружается в turbo-frame), полной HTML-страницей
      # быть не обязан.
    end
  end
end
