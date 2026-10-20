require "db"
require "json"
require "http/client"
require "random/secure"
require "sqlite3"
require "uuid"

# Leased-SQLite очередь джобов — порт src/jobs.js (once-campfire-express).
# Отдельная БД (db/jobs.sqlite3): claim по случайному lease-токену на 120 с,
# при ошибке retry с экспоненциальным backoff, после 5 попыток status='dead'.
# Запись батча — синхронно из HTTP-запроса до отправки ответа
# («persisted before response»). Воркер — JOB_CONCURRENCY фибр (default 3).
module Campfire
  class JobQueue
    class Job
      attr_reader id : Int64
      attr_reader payload : String
      attr_reader attempts : Int32
      attr_reader lease_token : String

      def initialize(@id, @payload, @attempts, @lease_token)
      end
    end

    SCHEMA = <<-SQL
      CREATE TABLE IF NOT EXISTS jobs(
        id INTEGER PRIMARY KEY,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        available_at REAL NOT NULL,
        lease_until REAL,
        lease_token TEXT,
        status TEXT NOT NULL DEFAULT 'ready',
        last_error TEXT
      )
    SQL

    @@db : DB::Database?

    # Межпроцессная сериализация писателей — flock (WriteQueue): к
    # SQLite процессы приходят строго по одному, BUSY-ошибки и
    # «отравление» соединений застрявшими стейтментами (perform_exec
    # шарда не делает reset при ошибке) не возникают. retry_on_lock —
    # страховка для внешних писателей (CLI-диагностика и т.п.).
    def self.db : DB::Database
      @@db ||= begin
        path = File.expand_path(ENV["CAMPFIRE_JOBS_DB"]? || "db/jobs.sqlite3")
        Dir.mkdir_p(File.dirname(path))
        # пул 2: writer-фибера (claim/enqueue/finish через WriteQueue)
        # + фибера периодического чекпоинта
        database = DB.open("sqlite3://#{path}?max_pool_size=2&max_idle_pool_size=2")
        database.setup_connection do |conn|
          # Межпроцессная сериализация писателей — flock в WriteQueue:
          # к SQLite они приходят по одному, busy-хендлер не участвует.
          # busy_timeout — чистая страховка от внешних писателей (CLI).
          conn.exec("PRAGMA busy_timeout=10000")
          # WAL обязателен (DELETE-журнал в fork-конфигурации ловил
          # "attempt to write a readonly database" на hot journal), но
          # авто-чекпоинты не завершаются под непрерывными клеймами —
          # wal_autocheckpoint=0 + PASSIVE-чекпоинт из checkpoint_fiber.
          conn.exec("PRAGMA journal_mode=WAL")
          conn.exec("PRAGMA wal_autocheckpoint=0")
          conn.exec("PRAGMA synchronous=NORMAL")
        end
        database.exec(SCHEMA)
        database
      end
    end

    # Периодический PASSIVE-чекпоинт jobs-WAL: без него непрерывные
    # читатели-клеймы не дают чекпоинтам завершаться, и WAL раздувался
    # до гигабайта при 0 строк. PASSIVE никого не блокирует.
    def self.start_checkpoint_fiber(interval : Time::Span = 3.seconds) : Nil
      spawn do
        loop do
          sleep interval
          begin
            db.exec("PRAGMA wal_checkpoint(PASSIVE)")
          rescue e
            STDERR.puts "Campfire jobs checkpoint failed: #{e.message}"
          end
        end
      end
    end

    # jobs: массив пар {kind, data} где data — JSON-строка.
    # BEGIN IMMEDIATE при busy_timeout=0: при конкуренции fork-воркеров
    # и job-фибр за write-lock SQLITE_BUSY возвращается мгновенно, ожидание
    # — фиберами retry_on_lock (event-loop воркера не блокируется).
    def self.enqueue_batch(jobs : Array(Tuple(String, String)),
                           at : Float64 = Time.utc.to_unix_f) : Nil
      return if jobs.empty?
      retry_on_lock do
        db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            jobs.each do |(kind, data)|
              payload = %({"kind":#{kind.to_json},"data":#{data}})
              conn.exec(
                "INSERT INTO jobs (payload, available_at) VALUES (?, ?)",
                payload, at)
            end
            conn.exec("COMMIT")
          rescue e
            conn.exec("ROLLBACK") rescue nil
            raise e
          end
        end
      end
    end

    # Claim через WriteQueue на единственном соединении очереди:
    # в процессе за jobs write-lock не конкурируют enqueue/claim/finish
    # (см. write_queue.cr), межпроцессная конкуренция — retry_on_lock.
    # Сначала SELECT без транзакции: пустой поллинг (клеймы каждые
    # 250 мс × JOB_CONCURRENCY × воркеры) не трогает write-lock вовсе.
    def self.claim(now : Float64 = Time.utc.to_unix_f) : Job?
      Campfire::WriteQueue.perform do
        has_row = db.using_connection do |conn|
          conn.query_one?(
            "SELECT 1 FROM jobs WHERE status='ready' AND available_at <= ? " \
            "AND (lease_until IS NULL OR lease_until <= ?) LIMIT 1",
            now, now) { |rs| rs.read(Int32) }
        end
        next nil unless has_row

        retry_on_lock do
          db.using_connection do |conn|
            conn.exec("BEGIN IMMEDIATE")
            begin
              row = conn.query_one?(
                "SELECT id, payload, attempts FROM jobs " \
                "WHERE status='ready' AND available_at <= ? " \
                "AND (lease_until IS NULL OR lease_until <= ?) ORDER BY id LIMIT 1",
                now, now) do |rs|
                {id: rs.read(Int64), payload: rs.read(String), attempts: rs.read(Int32)}
              end
              job = nil
              if row
                token = Random::Secure.hex(16)
                conn.exec(
                  "UPDATE jobs SET attempts = attempts + 1, lease_until = ?, lease_token = ? WHERE id = ?",
                  now + 120, token, row[:id])
                job = Job.new(row[:id], row[:payload], row[:attempts] + 1, token)
              end
              conn.exec("COMMIT")
              job
            rescue e
              conn.exec("ROLLBACK") rescue nil
              raise e
            end
          end
        end
      end
    end

    def self.finish(job : Job, error : String? = nil,
                    now : Float64 = Time.utc.to_unix_f) : Nil
      Campfire::WriteQueue.perform do
        retry_on_lock do
          db.using_connection do |conn|
            if error.nil?
              conn.exec("DELETE FROM jobs WHERE id = ? AND lease_token = ?",
                job.id, job.lease_token)
            else
              backoff = Math.min(300, 2 ** job.attempts)
              conn.exec(
                "UPDATE jobs SET lease_until = NULL, lease_token = NULL, " \
                "available_at = ?, status = ?, last_error = ? " \
                "WHERE id = ? AND lease_token = ?",
                now + backoff,
                job.attempts >= 5 ? "dead" : "ready",
                error[0, 1000],
                job.id, job.lease_token)
            end
          end
        end
      end
    end

    def self.start_worker : Nil
      concurrency = ENV["JOB_CONCURRENCY"]?.try(&.to_i?) || 3
      concurrency.times { spawn { worker_loop } }
      start_checkpoint_fiber
    end

    # После fork (serverX Cluster): унаследованные sqlite-дескрипторы
    # нельзя использовать — закрыть и открыть заново лениво.
    def self.reset! : Nil
      @@db.try(&.close)
      @@db = nil
    end

    # См. комментарий у enqueue_batch: мгновенный SQLITE_BUSY лечится
    # повтором со свежим снапшотом. 30 коротких попыток: окно конкуренции
    # суб-миллисекундное, длинные рандомные сны лишь простоивали лок;
    # "statements in progress" ретраится потому же (застрявший после
    # ошибки стейтмент самолечится повторным exec на том же соединении).
    private def self.retry_on_lock(attempts : Int32 = 30, &)
      tries = 0
      loop do
        tries += 1
        begin
          return yield
        rescue e : SQLite3::Exception
          msg = e.message.to_s
          if (msg.includes?("database is locked") ||
              msg.includes?("statements in progress")) && tries < attempts
            sleep Random.new.rand(0.001..0.008).seconds
            next
          end
          raise e
        end
      end
      raise Exception.new("unreachable") # исключает Nil из типа возврата
    end

    def self.worker_loop : Nil
      loop do
        job = begin
          claim
        rescue e
          STDERR.puts "Campfire queue failed: #{e.message}"
          nil
        end
        unless job
          sleep 0.25.seconds
          next
        end
        begin
          payload = JSON.parse(job.payload)
          perform(payload["kind"].to_s, payload["data"])
          finish(job)
        rescue e
          STDERR.puts "Campfire job failed: #{e.message}"
          begin
            finish(job, e.message.to_s)
          rescue e2
            STDERR.puts "Campfire job bookkeeping failed: #{e2.message}"
          end
        end
      end
    end

    # ————— Хендлеры (порт perform из src/jobs.js) —————

    def self.perform(kind : String, data : JSON::Any) : Nil
      case kind
      when "push"     then perform_push(data)
      when "webhook"  then perform_webhook(data)
      when "remove_banned_content" then perform_remove_banned_content(data)
      else                 raise "unknown job #{kind}"
      end
    end

    # Web Push (VAPID) — порт Room::PushMessageJob + Room::MessagePusher
    # (message_pusher.rb): получатели — активные (User.active) подписчики
    # комнаты, involvement everything ИЛИ mentions+mentionees, кроме
    # создателя и connected-пользователей (Membership.visible.disconnected,
    # TTL 60с); payload — title/body по room_type (direct — имя создателя,
    # shared — имя комнаты), badge непрочитанных (Pool#queue), icon —
    # логотип аккаунта (WebPush::Notification#encoded_message); доставка —
    # WebPush.deliver (aes128gcm + VAPID + DNS-pinning); 404/410 —
    # подписка мертва (удаляем), >=400 — исключение → retry джобы.
    # Без ключей окружения — успешный no-op.
    def self.perform_push(data : JSON::Any) : Nil
      return unless (vapid_private = ENV["VAPID_PRIVATE_KEY"]?) &&
                    (vapid_public = ENV["VAPID_PUBLIC_KEY"]?)
      message_id = data["message_id"]?.try(&.to_s.to_i64?)
      return unless message_id

      conn = ActiveRecord::Base.connection
      message = conn.query_one?(
        "SELECT r.id AS room_id, r.name AS room_name, r.type AS room_type, " \
        "m.creator_id, u.name AS creator_name FROM messages m " \
        "JOIN rooms r ON r.id = m.room_id JOIN users u ON u.id = m.creator_id WHERE m.id = ?",
        message_id) do |rs|
        {room_id: rs.read(Int64), room_name: rs.read(String?),
         room_type: rs.read(String?), creator_id: rs.read(Int64),
         creator_name: rs.read(String?)}
      end
      return unless message

      # messagePlainText: тело сообщения или имя вложения
      body = conn.query_one?(
        "SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?",
        message_id) { |rs| rs.read(String) }.to_s
      plain = MessageCreator.plain_text(body)
      if plain.empty?
        plain = conn.query_one?(
          "SELECT b.filename FROM active_storage_attachments a " \
          "JOIN active_storage_blobs b ON b.id = a.blob_id " \
          "WHERE a.record_type = 'Message' AND a.record_id = ? AND a.name = 'attachment'",
          message_id) { |rs| rs.read(String) }.to_s
      end

      # STI-порт пишет короткие имена ("Direct"), reference-сиды — полные
      # ("Rooms::Direct"); проверяем обе формы.
      direct = message[:room_type].in?("Direct", "Rooms::Direct")
      title = direct ? message[:creator_name] : message[:room_name]
      message_body = direct ? plain : "#{message[:creator_name]}: #{plain}"

      # MessagePusher#push: push_subscriptions_for_users_involved_in_
      # everything.or(push_subscriptions_for_mentionable_users(mentionees))
      # — один JOIN по relevant_subscriptions (User.active +
      # Membership.visible.disconnected.where(room).not(creator)); ветка
      # mentions дополнительно требует упоминания (message.mentionees).
      mentions = MessageCreator.mention_ids(body)
      subscriptions = conn.query_all(
        "SELECT ps.id, ps.user_id, ps.endpoint, ps.p256dh_key, ps.auth_key, " \
        "m.involvement FROM push_subscriptions ps " \
        "JOIN users u ON u.id = ps.user_id " \
        "JOIN memberships m ON m.user_id = ps.user_id " \
        "WHERE m.room_id = ? AND m.user_id <> ? AND u.status = 0 " \
        "AND m.involvement <> 'invisible' " \
        "AND (m.connected_at IS NULL OR m.connected_at < ?) " \
        "AND (m.involvement = 'everything' OR m.involvement = 'mentions')",
        message[:room_id], message[:creator_id],
        Time.utc - 60.seconds) do |rs|
        {id: rs.read(Int64), user_id: rs.read(Int64), endpoint: rs.read(String?),
         p256dh: rs.read(String?), auth: rs.read(String?), involvement: rs.read(String?)}
      end

      subject = ENV["VAPID_SUBJECT"]? || "mailto:campfire@example.com"
      badges = {} of Int64 => Int64
      subscriptions.each do |sub|
        next if sub[:involvement] == "mentions" && !mentions.includes?(sub[:user_id])
        next if sub[:endpoint].nil? || sub[:p256dh].nil? || sub[:auth].nil?
        # Pool#queue: badge — Membership.unread по каждому получателю
        badges[sub[:user_id]] ||= conn.query_one(
          "SELECT count(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL",
          sub[:user_id], as: Int64)
        payload = JSON.build do |j|
          j.object do
            j.field "title", title
            j.field "options" do
              j.object do
                j.field "body", message_body
                j.field "icon", "/account/logo"
                j.field "data" do
                  j.object do
                    j.field "path", "/rooms/#{message[:room_id]}"
                    j.field "badge", badges[sub[:user_id]]
                  end
                end
              end
            end
          end
        end
        status = WebPush.deliver(sub[:endpoint].not_nil!, sub[:p256dh].not_nil!,
          sub[:auth].not_nil!, payload, vapid_public, vapid_private, subject)
        # nil — не-https endpoint или приватный адрес: skip (continue у express)
        next unless status
        if {404, 410}.includes?(status)
          conn.exec("DELETE FROM push_subscriptions WHERE id = ?", sub[:id])
        elsif status >= 400
          raise "push HTTP #{status}"
        end
      end
    end

    # RemoveBannedContentJob (remove_banned_content_job.rb референса):
    # User#remove_banned_content — destroy всех сообщений юзера с
    # broadcast_remove каждого. Шаги удаления — как messages#destroy
    # порта (ActionText-тело + FTS5-индекс + строка), boosts —
    # dependent: :destroy референса (express deleteMessage).
    def self.perform_remove_banned_content(data : JSON::Any) : Nil
      user_id = data["user_id"]?.try(&.to_s.to_i64?)
      return unless user_id

      conn = ActiveRecord::Base.connection
      messages = conn.query_all(
        "SELECT id, room_id FROM messages WHERE creator_id = ? ORDER BY id", user_id) do |rs|
        {id: rs.read(Int64), room_id: rs.read(Int64)}
      end

      messages.each do |message|
        mid = message[:id]
        conn.exec("DELETE FROM boosts WHERE message_id = ?", mid)
        conn.exec(
          "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
        conn.exec("DELETE FROM message_search_index WHERE rowid=?", mid)
        conn.exec("DELETE FROM messages WHERE id = ?", mid)
        # Message::Broadcasts#broadcast_remove: стрим [room, "messages"],
        # target — dom_id сообщения (cable-фрейм, без хвостового \n).
        if (room = Room.find?(message[:room_id]))
          Turbo::StreamsChannel.broadcast_remove_to([room, "messages"],
            target: "message_#{mid}")
        end
      end
      Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    end

    def self.perform_webhook(data : JSON::Any) : Nil
      webhook_id = data["webhook_id"]?.try(&.to_s.to_i64?)
      message_id = data["message_id"]?.try(&.to_s.to_i64?)
      return unless webhook_id && message_id

      conn = ActiveRecord::Base.connection
      hook = conn.query_one?(
        "SELECT w.id, w.url, w.user_id, u.name, u.bot_token, u.status " \
        "FROM webhooks w JOIN users u ON u.id = w.user_id WHERE w.id = ?",
        webhook_id) do |rs|
        {id: rs.read(Int64), url: rs.read(String?), user_id: rs.read(Int64),
         name: rs.read(String?), bot_token: rs.read(String?), status: rs.read(Int32)}
      end
      return unless hook && hook[:status] == 0

      message = conn.query_one?(
        "SELECT m.id, m.room_id, m.creator_id, r.name AS room_name, r.type AS room_type, " \
        "u.name AS creator_name FROM messages m " \
        "JOIN rooms r ON r.id = m.room_id JOIN users u ON u.id = m.creator_id WHERE m.id = ?",
        message_id) do |rs|
        {id: rs.read(Int64), room_id: rs.read(Int64), creator_id: rs.read(Int64),
         room_name: rs.read(String?), room_type: rs.read(String?),
         creator_name: rs.read(String?)}
      end
      return unless message
      return unless conn.query_one?(
        "SELECT 1 FROM memberships WHERE user_id = ? AND room_id = ?",
        hook[:user_id], message[:room_id]) { |rs| rs.read(Int32) }

      body = conn.query_one?(
        "SELECT body FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?",
        message[:id]) { |rs| rs.read(String) }.to_s

      payload = JSON.build do |j|
        j.object do
          j.field "user" do
            j.object do
              j.field "id", message[:creator_id]
              j.field "name", message[:creator_name]
            end
          end
          j.field "room" do
            j.object do
              j.field "id", message[:room_id]
              j.field "name", message[:room_name]
              j.field "path", "/rooms/#{message[:room_id]}/#{hook[:user_id]}-#{hook[:bot_token]}/messages"
            end
          end
          j.field "message" do
            j.object do
              j.field "id", message[:id]
              j.field "body" do
                j.object do
                  j.field "html", body
                  j.field "plain", MessageCreator.plain_text(body)
                end
              end
              j.field "path", "/rooms/#{message[:room_id]}/@#{message[:id]}"
            end
          end
        end
      end

      url = URI.parse(hook[:url].to_s)
      if !{"http", "https"}.includes?(url.scheme) || url.user || url.password
        raise "invalid webhook URL"
      end

      reply_text = deliver_webhook(url, payload)
      if reply_text
        webhook_reply(hook[:user_id], message[:room_id], reply_text)
      end
    rescue IO::TimeoutError
      if hook && message
        webhook_reply(hook[:user_id], message[:room_id],
          "Failed to respond within 7 seconds")
      end
    end

    # POST JSON; ответ 200 + text/* → текст-реплай от бота, иначе nil.
    def self.deliver_webhook(url : URI, payload : String) : String?
      client = HTTP::Client.new(url)
      client.connect_timeout = 7.seconds
      client.read_timeout = 7.seconds
      response = client.post(url.request_target.not_nil!,
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: payload)
      content_type = response.headers["Content-Type"]?.to_s.split(";").first?
      if response.status_code == 200 &&
         {"text/plain", "text/html"}.includes?(content_type) &&
         !response.body.empty?
        response.body
      end
    end

    # Ответ бота — сообщение от его имени (webhooks: false — как
    # notifyMessage(result, { webhooks: false }) у express).
    def self.webhook_reply(bot_id : Int64, room_id : Int64, text : String) : Nil
      room = Room.find?(room_id)
      bot = User.find?(bot_id)
      return unless room && bot
      body_html = "<p>#{HTML.escape(text)}</p>"
      MessageCreator.create!(room, bot, body_html, UUID.random.to_s,
        webhooks: false)
    end
  end
end
