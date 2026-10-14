require "json"

# Создание сообщения со всеми побочными эффектами комнаты — порт
# MessagesController#create + Room#receive + notifyMessage
# (once-campfire-express): вставка + ActionText-тело + FTS5-индекс +
# turbo-stream broadcast + unread_memberships + постановка джобов
# уведомлений (push/webhook) в leased-SQLite очередь — всё persisted ДО
# HTTP-ответа.
module MessageCreator
  # Возвращает созданное сообщение (после вставки тела/индекса и broadcast).
  def self.create!(room : Room, creator : User, body_html : String,
                   client_message_id : String, webhooks : Bool = true) : Message
    now = Time.utc
    message = Message.new(
      room_id: room.id.not_nil!,
      creator_id: creator.id.not_nil!,
      client_message_id: client_message_id)
    message.save!
    message_id = message.id.not_nil!

    plain = plain_text(body_html)
    conn = ActiveRecord::Base.connection
    conn.exec(
      "INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
      "Message", message_id, "body", body_html.empty? ? plain : body_html, now, now)
    conn.exec(
      "INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)",
      message_id, plain)

    broadcast(room, message, creator)
    notify(room, message, creator, body_html, webhooks)
    message
  end

  def self.broadcast(room : Room, message : Message, author : User) : Nil
    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_room_#{room.id}"><template>)
      io << ChatLayout.message_dom(message, room, author)
      io << %(</template></turbo-stream>\n)
    end
    Turbo.cable.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      turbo_frame)
  end

  # Room#receive: unread для участников, отключённых дольше 60 секунд,
  # затем сборка джобов уведомлений (notifyMessage у express).
  def self.notify(room : Room, message : Message, creator : User,
                  body_html : String, webhooks : Bool) : Nil
    conn = ActiveRecord::Base.connection
    now = Time.utc
    conn.exec(
      "UPDATE memberships SET unread_at = ?, updated_at = ? " \
      "WHERE room_id = ? AND user_id <> ? AND involvement <> 'invisible' " \
      "AND (connected_at IS NULL OR connected_at < ?)",
      now, now, room.id.not_nil!, creator.id.not_nil!, now - 60.seconds)

    mentions = mention_ids(body_html)
    direct = room.type == "Direct" # STI-порт хранит короткие имена
    jobs = [] of Tuple(String, String)

    rows = conn.query_all(
      "SELECT m.user_id, m.involvement, u.role, u.status, " \
      "(m.connected_at IS NULL OR m.connected_at < ?) AS offline " \
      "FROM memberships m JOIN users u ON u.id = m.user_id " \
      "WHERE m.room_id = ? AND m.user_id <> ?",
      now - 60.seconds, room.id.not_nil!, creator.id.not_nil!) do |rs|
      {user_id: rs.read(Int64), involvement: rs.read(String?),
       role: rs.read(Int32), status: rs.read(Int32), offline: rs.read(Int64)}
    end

    rows.each do |row|
      mentioned = mentions.includes?(row[:user_id])
      if webhooks && row[:status] == 0 && row[:role] == 2 && (direct || mentioned)
        conn.query_all(
          "SELECT id FROM webhooks WHERE user_id = ?", row[:user_id]) do |rs|
          rs.read(Int64)
        end.each do |webhook_id|
          data = JSON.build do |j|
            j.object do
              j.field "webhook_id", webhook_id
              j.field "message_id", message.id.not_nil!
            end
          end
          jobs << {"webhook", data}
        end
      end
      if row[:offline] == 1 &&
         (row[:involvement] == "everything" ||
          (row[:involvement] == "mentions" && mentioned))
        data = JSON.build do |j|
          j.object do
            j.field "user_id", row[:user_id]
            j.field "message_id", message.id.not_nil!
          end
        end
        jobs << {"push", data}
      end
    end

    Campfire::JobQueue.enqueue_batch(jobs)
  end

  # Грубое html→text для FTS5-индекса: контракту достаточно вхождения
  # слов тела; теги вырезаем.
  def self.plain_text(html : String) : String
    html.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
  end

  # ————— Упоминания (порт mentionIds + unverifiedUserGid, richtext.js) —————

  def self.mention_ids(body : String) : Set(Int64)
    ids = Set(Int64).new
    body.scan(/<action-text-attachment\b[^>]*\bsgid=["']([^"']+)/) do |match|
      if (gid = match[1]?) && (user_id = unverified_user_gid(gid))
        ids << user_id
      end
    end
    ids
  end

  # sgid без проверки подписи: base64-конверт Rails-конверта `_rails`,
  # gid-URL вида gid://<app>/User/<id>.
  def self.unverified_user_gid(raw : String) : Int64?
    envelope_raw = raw[0...(raw.rindex("--") || return)]
    json = decode_base64_lenient(envelope_raw) || return nil
    envelope = JSON.parse(json)
    message = envelope["_rails"]?
    return nil unless message.is_a?(JSON::Any)
    value = message["data"]?
    if value.nil? || (value.to_s.empty? && message["message"]?)
      decoded = decode_base64_lenient(message["message"].to_s) || return nil
      gid = decoded[/gid:\/\/[^\s]+\/\d+/]?
      return nil unless gid
      return gid[/\/User\/(\d+)$/, 1]?.try(&.to_i64?)
    end
    value = value.to_s
    value = decode_base64_lenient(value) || return nil unless value.starts_with?("gid:")
    if (match = value.match(/\/User\/(\d+)$/)) && value.starts_with?("gid://")
      match[1].to_i64?
    end
  end

  # Base64 (возможно urlsafe, без паддинга) — lenient, как Buffer.from.
  def self.decode_base64_lenient(text : String) : String?
    sanitized = text.tr("-_", "+/").gsub(/\s+/, "")
    sanitized += "=" * ((4 - sanitized.size % 4) % 4)
    Base64.decode_string(sanitized)
  rescue
    nil
  end
end
