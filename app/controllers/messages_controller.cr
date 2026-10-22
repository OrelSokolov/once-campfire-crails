require "uuid"

# GET /rooms/:id/messages?before=<anchor_id> — страница истории
# (контракт: 40 сообщений STRICTLY BEFORE anchor по created_at, вывод ASC).
# POST /rooms/:id/messages — создание сообщения (контракт: turbo-stream
# append; аудит: messages + action_text_rich_texts + FTS5 с телом).
class MessagesController < ApplicationController
  include MessagesHelpers

  def index
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!
    user = current_user.not_nil!

    # Whole-page cache (как rooms#show): ключ включает query
    # (?before=...), инвалидация — общий DB-epoch.
    page = cache_page("messages#index", user.id) do
      messages = find_messages(room)
      # Rails messages#index: пустая страница → 204 No Content (пагинатор
      # по нему понимает, что история дочитана). Rails: head :no_content —
      # без тела и без Content-Type (не кэшируется).
      return head(:no_content) if messages.empty?
      Campfire::PageCache::Page.new(messages_page_html(room, messages, db_epoch))
    end
    send_page(page)
  end

  # messages#index: before → 40 строго до anchor по created_at (вывод ASC),
  # after → 40 строго после (ASC), без anchor — последние 40 ASC.
  private def find_messages(room : Room) : Array(Message)
    anchor = params["before"]?
    after_anchor = params["after"]?
    if anchor && (anchor_id = anchor.to_s.to_i64?)
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
    # Без хвостового \n: у Rails @message_html = render_to_string партиала
    # (Erubi глотает переводы после <% end %>), Turbo не должен аппендить
    # текстовый узел-пробел после сообщения в контейнер.
    message_html = ChatLayout.message_dom(message, room, user, attachment, base_url: origin).chomp
    render(html: append_message_stream(room, message_html),
      content_type: "text/vnd.turbo-stream.html")
  end

  # Bot-API (/rooms/:id/:bot_key/messages/**) — Messages::ByBotsController
  # и Messages::Boosts::ByBotsController (см. app/controllers/messages/).

  # show.html.erb (render @message): страница с DOM сообщения. Turbo
  # извлекает из ответа фрейм edit_message_<id> — это завершает навигацию
  # фрейма после редиректа update (фрейм получает [complete]) и
  # подтягивает отрендеренное сообщение.
  # show.html.erb / edit.html.erb
  # Геттеры — для ERB-хелперов MessagesHelpers (модуль не видит ивары).
  attr_reader :room, :message, :mid, :attachment
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

    # messages_controller.rb#destroy: broadcast_remove (cable-фрейм — без
    # хвостового \n); HTTP-ответ — destroy.turbo_stream.erb (тег + \n файла).
    broadcast_remove_to([room, "messages"], target: "message_#{mid}")
    render(html: %(<turbo-stream action="remove" target="message_#{mid}"></turbo-stream>\n),
      content_type: "text/vnd.turbo-stream.html")
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
      # touch сообщения (аналог AR updated_at при update!)
      target.not_nil!.touch
    end

    message = Message.find?(message.id.not_nil!).not_nil!
    mid = message.id.not_nil!
    # messages_controller.rb#update: broadcast_replace_to @room, :messages,
    # target: [ @message, :presentation ], partial: "messages/presentation",
    # attributes: { maintain_scroll: true } (attributes — через
    # broadcast_action_to); presentation_dom уже кончается \n, как
    # _presentation.html.erb.
    broadcast_action_to([room, "messages"], :replace,
      target: "presentation_message_#{mid}",
      html: ChatLayout.presentation_dom(mid, ChatLayout.text_presentation(message.body.to_s)),
      attributes: {"maintain_scroll" => "true"})
    redirect_to room_message_path(room.id.not_nil!, mid)
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
end
