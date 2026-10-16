require "json"
require "sqlite3"
require "digest/md5"

# Создание сообщения со всеми побочными эффектами комнаты — порт
# MessagesController#create + Room#receive + notifyMessage
# (once-campfire-express): вставка + ActionText-тело + FTS5-индекс +
# turbo-stream broadcast + unread_memberships + постановка джобов
# уведомлений (push/webhook) в leased-SQLite очередь — всё persisted ДО
# HTTP-ответа.
module MessageCreator
  # Загруженный файл (multipart от file_uploader.js): клиент шлёт файл
  # прямо в POST /rooms/:id/messages, без ActiveStorage direct uploads.
  record UploadedFile, filename : String, content_type : String, bytes : Bytes

  # Возвращает созданное сообщение (после вставки тела/индекса и broadcast).
  # attachment: сохранить файл как blob + active_storage_attachments
  # (storage.js storeUpload + attachMessage; FTS-индекс — тело или filename).
  def self.create!(room : Room, creator : User, body_html : String,
                   client_message_id : String, webhooks : Bool = true,
                   attachment : UploadedFile? = nil) : Message
    now = Time.utc
    plain = plain_text(body_html)

    # Одна атомарная транзакция на production-БД: message + rich text +
    # FTS5 + unread. Атомарность обязательна для retry: повтор после
    # "database is locked" не должен оставлять сообщений без тела/индекса
    # (аудит write_ack'ов сверяет каждую запись).
    #
    # Производственная транзакция и постановка джобов идут через
    # Campfire::WriteQueue: в процессе пишет одна writer-фибера (см.
    # write_queue.cr — почему конкурентный BEGIN IMMEDIATE из фибер
    # лайвлокит воркер). Broadcast и инвалидация кэша — после, вне
    # очереди.
    message = Campfire::WriteQueue.perform do
      created = retry_on_lock do
        ActiveRecord::Base.transaction do
          record = Message.new(
            room_id: room.id.not_nil!,
            creator_id: creator.id.not_nil!,
            client_message_id: client_message_id)
          record.save!
          message_id = record.id.not_nil!

          conn = ActiveRecord::Base.__session # pinned-коннект транзакции
          conn.exec(
            "INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
            "Message", message_id, "body", body_html.empty? ? plain : body_html, now, now)
          store_attachment(conn, message_id, attachment, now) if attachment
          # indexMessage: plainText(body) || filename — файл без текста
          # индексируется именем файла.
          conn.exec(
            "INSERT INTO message_search_index (rowid, body) VALUES ($1, $2)",
            message_id, plain.presence || attachment.try(&.filename) || "")

          pending_jobs = notify(room, record, creator, body_html, webhooks)
          {record: record, jobs: pending_jobs}
        end
      end.not_nil!
      # Постановка джобов (отдельная БД очереди) — строго ПОСЛЕ commit
      # production-транзакции: ожидание write-lock очереди внутри чужой
      # транзакции держит production write-lock и заводит конвейер из
      # двух пулов (наблюдали полный дедлок приложения при conc=16).
      Campfire::JobQueue.enqueue_batch(created[:jobs])
      created
    end
    # Broadcast с вложением, если файл был сохранён (attachMessage →
    # publishMessage: presentation вместо rich-text тела).
    record = message[:record]
    rendered = attachment ? ChatLayout.attachments_for([record.id.not_nil!])[record.id.not_nil!]? : nil
    broadcast(room, record, creator, rendered)
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    record
  end

  def self.broadcast(room : Room, message : Message, author : User,
                     attachment : ChatLayout::Attachment? = nil) : Nil
    turbo_frame = String.build do |io|
      io << %(<turbo-stream action="append" target="messages_room_#{room.id}"><template>)
      io << ChatLayout.message_dom(message, room, author, attachment)
      io << %(</template></turbo-stream>\n)
    end
    Campfire.broadcast(
      Turbo::Streams::StreamName.stream_name_from([room, "messages"]),
      turbo_frame)
  end

  # storeUpload + attachMessage (storage.js/routes.js): файл на диск в
  # <root>/<key[0,2]>/<key[2,2]>/<key> (тот же путь, из которого файлы
  # отдаёт ActiveStorageController), blob-строка (md5-checksum в base64,
  # key = 28 hex) и attachment на Message + touch messages.updated_at.
  private def self.store_attachment(conn, message_id : Int64,
                                    upload : UploadedFile, now : Time) : Nil
    key = Random::Secure.hex(14)
    root = ENV["CAMPFIRE_STORAGE_ROOT"]? || "storage"
    dir = File.join(root, key[0, 2], key[2, 2])
    Dir.mkdir_p(dir)
    File.write(File.join(dir, key), upload.bytes)

    checksum = Base64.strict_encode(Digest::MD5.digest(upload.bytes))
    filename = File.basename(upload.filename.presence || "file")
    content_type = upload.content_type.presence || "application/octet-stream"
    blob_id = conn.exec(
      "INSERT INTO active_storage_blobs (key, filename, content_type, byte_size, checksum, metadata, service_name, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      key, filename, content_type, upload.bytes.size.to_i64, checksum,
      "{}", "local", now).last_insert_id
    conn.exec(
      "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) VALUES ('attachment', 'Message', $1, $2, $3)",
      message_id, blob_id, now)
    conn.exec("UPDATE messages SET updated_at = $1 WHERE id = $2", now, message_id)
  end

  # Room#receive: unread для участников, отключённых дольше 60 секунд,
  # затем сборка джобов уведомлений (notifyMessage у express). Возвращает
  # собранные джобы — постановка в очередь выполняет вызывающий ПОСЛЕ
  # commit production-транзакции.
  def self.notify(room : Room, message : Message, creator : User,
                  body_html : String, webhooks : Bool) : Array(Tuple(String, String))
    conn = ActiveRecord::Base.__session # pinned-коннект транзакции create!
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
    jobs
  end

  # Грубое html→text для FTS5-индекса: контракту достаточно вхождения
  # слов тела; теги вырезаем.
  def self.plain_text(html : String) : String
    html.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
  end

  # Транзакция стартует BEGIN IMMEDIATE (active_record.cr 0.1.2, как
  # Rails 8.1 sqlite3_adapter): писатель берёт write-lock сразу и ждёт
  # его через busy_timeout драйвера. Повтор остаётся страховкой от
  # истечения busy_timeout при сильной конкуренции fork-воркеров —
  # повтор транзакции целиком берёт свежий снапшот.
  private def self.retry_on_lock(attempts : Int32 = 5, &)
    tries = 0
    loop do
      tries += 1
      begin
        return yield
      rescue e : SQLite3::Exception
        if e.message.to_s.includes?("database is locked") && tries < attempts
          sleep Random.new.rand(0.005..0.05)
          next
        end
        raise e
      end
    end
    raise Exception.new("unreachable") # исключает Nil из типа возврата
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
