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
  alias UploadedFile = Message::Attachment::UploadedFile

  # Возвращает созданное сообщение (после вставки тела/индекса и broadcast).
  # attachment: сохранить файл как blob + active_storage_attachments
  # (storage.js storeUpload + attachMessage; FTS-индекс — тело или filename).
  def self.create!(room : Room, creator : User, body_html : String,
                   client_message_id : String, webhooks : Bool = true,
                   attachment : UploadedFile? = nil,
                   base_url : String = "") : Message
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
          record.save! # belongs_to :room, touch: true трогает rooms.updated_at
          message_id = record.id.not_nil!

          conn = ActiveRecord::Base.__session # pinned-коннект транзакции
          conn.exec(
            "INSERT INTO action_text_rich_texts (record_type, record_id, name, body, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6)",
            "Message", message_id, "body", body_html.empty? ? plain : body_html, now, now)
          Message::Attachment.store(conn, record, attachment, now) if attachment
          # indexMessage: plainText(body) || filename — файл без текста
          # индексируется именем файла.
          Message::Searchable.insert_in_index(conn, message_id,
            plain.presence || attachment.try(&.filename) || "")

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
    Message::Broadcasts.broadcast_create(room, record, creator, rendered, base_url)
    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша
    record
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

    mentions = Message::Mentionee.mention_ids(body_html)
    direct = room.type == "Direct" # STI-порт хранит короткие имена
    jobs = [] of Tuple(String, String)

    rows = conn.query_all(
      "SELECT m.user_id, u.role, u.status " \
      "FROM memberships m JOIN users u ON u.id = m.user_id " \
      "WHERE m.room_id = ? AND m.user_id <> ?",
      room.id.not_nil!, creator.id.not_nil!) do |rs|
      {user_id: rs.read(Int64), role: rs.read(Int32), status: rs.read(Int32)}
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
    end

    # Room::PushMessageJob (message.rb: after_create_commit →
    # room.push_later): единая push-джоба на сообщение; получатели
    # (Room::MessagePusher) фильтруются при доставке.
    jobs << {"push", %({"message_id":#{message.id.not_nil!}})}
    # Message::BroadcastUnreadRoomJob: fanout непрочитанных в сайдбар
    # (UnreadRoomsChannel, per-user стримы).
    jobs << {"broadcast_unread_room", %({"message_id":#{message.id.not_nil!}})}
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
          sleep Random.new.rand(0.005..0.05).seconds
          next
        end
        raise e
      end
    end
    raise Exception.new("unreachable") # исключает Nil из типа возврата
  end
end
