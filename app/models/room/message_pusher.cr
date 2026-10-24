require "../application_record"

# Push notifications for a new message; no-op unless VAPID keys are configured.
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

      # STI type is stored in two spellings: short ("Direct") from the port, full ("Rooms::Direct") from reference seeds.
      direct = message[:room_type].in?("Direct", "Rooms::Direct")
      title = direct ? message[:creator_name] : message[:room_name]
      message_body = direct ? plain : "#{message[:creator_name]}: #{plain}"

      mentions = Message::Mentionee.mention_ids(body)
      # Banning keeps the user's subscriptions, so that unbanning brings their notifications back,
      # but nobody who can't sign in should be sent what's said in their rooms meanwhile.
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
        # nil means non-https endpoint or private address: skip.
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
