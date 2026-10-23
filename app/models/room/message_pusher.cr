require "../application_record"

# Room::MessagePusher (room/message_pusher.rb референса): получатели
# push-уведомления — активные (User.active) подписчики комнаты,
# involvement everything ИЛИ mentions+mentionees, кроме создателя и
# connected-пользователей (Membership.visible.disconnected, TTL 60с);
# payload — title/body по room_type (direct — имя создателя, shared —
# имя комнаты), badge непрочитанных (Pool#queue), icon — логотип
# аккаунта (WebPush::Notification#encoded_message); доставка —
# WebPush.deliver (aes128gcm + VAPID + DNS-pinning); 404/410 —
# подписка мертва (удаляем), >=400 — исключение → retry джобы.
# Без ключей окружения — успешный no-op.
class Room
  module MessagePusher
    def self.push(message_id : Int64) : Nil
      return unless (vapid_private = ENV["VAPID_PRIVATE_KEY"]?) &&
                    (vapid_public = ENV["VAPID_PUBLIC_KEY"]?)

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

      # push_subscriptions_for_users_involved_in_everything
      # .or(push_subscriptions_for_mentionable_users(mentionees)) — один
      # JOIN по relevant_subscriptions (User.active +
      # Membership.visible.disconnected.where(room).not(creator)); ветка
      # mentions дополнительно требует упоминания (message.mentionees).
      mentions = Message::Mentionee.mention_ids(body)
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
        status = Campfire::WebPush.deliver(sub[:endpoint].not_nil!, sub[:p256dh].not_nil!,
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
  end
end
