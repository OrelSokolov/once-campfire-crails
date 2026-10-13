require "uuid"

# GET /rooms/:id/messages?before=<anchor_id> — страница истории
# (контракт: 40 сообщений STRICTLY BEFORE anchor по created_at, вывод ASC).
# POST /rooms/:id/messages — создание сообщения (контракт: turbo-stream
# append; аудит: messages + action_text_rich_texts + FTS5 с телом).
class MessagesController < ApplicationController
  def index
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
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

    render_messages_page(room, messages)
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

    # Вставка сообщения + ActionText-тела + FTS5-индекс (аудит validate_acks
    # требует все три с точным телом).
    now = Time.utc
    message = Message.new(
      room_id: room.id.not_nil!,
      creator_id: user.id.not_nil!,
      client_message_id: client_message_id)
    message.save!
    message_id = message.id.not_nil!

    conn = ActiveRecord::Base.connection
    plain = plain_text(body_html)
    conn.exec(
      "INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
      "Message", message_id, "body", body_html.empty? ? plain : body_html, now, now)
    conn.exec(
      "INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)",
      message_id, plain)

    # Контракт ответа: text/vnd.turbo-stream.html, action="append",
    # target = единственный messages_room_<id>; DOM сообщения с
    # data-message-id, чтобы loadgen извлёк подтверждённый id.
    # Тот же кадр уходит в cable-стрим комнаты (RoomMessagesChannel).
    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_room_#{room.id}">)
      io << %(<template><article id="message_#{message_id}" data-message-id="#{message_id}" data-client-message-id=")
      io << HTML.escape(client_message_id)
      io << %("\n  ><div class="message-body">) << body_html << "</div></article></template>"
      io << "</turbo-stream>\n"
    end

    Turbo.cable.broadcast(
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

  private def render_messages_page(room, messages)
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << "<!doctype html>\n<html>\n<head><title>"
      io << HTML.escape(room.name.to_s)
      io << "</title></head>\n<body>\n"
      io << %(<main id="messages_room_#{room.id}">\n)
      messages.each do |m|
        io << %(  <article id="message_#{m.id}" data-message-id="#{m.id}" data-client-message-id=")
        io << HTML.escape(m.client_message_id.to_s)
        io << %("\n    >)
        io << %(<div class="message-body">) << m.body.to_s << "</div>\n"
        io << "  </article>\n"
      end
      io << "</main>\n</body>\n</html>\n"
    end)
  end
end
