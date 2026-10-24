require "../application_record"

class User
  module Bannable
    # Ban: bans from the user's session IPs (DISTINCT, no blanks), delete sessions (sign out),
    # status banned (2). Content is removed asynchronously by the remove_banned_content job —
    # enqueued strictly after commit, like notify in MessageCreator.
    def ban : Nil
      uid = id.not_nil!
      now = Time.utc
      Campfire::WriteQueue.perform do
        ActiveRecord::Base.transaction do
          conn = ActiveRecord::Base.__session # pinned transaction connection
          conn.query_all(
            "SELECT DISTINCT ip_address FROM sessions " \
            "WHERE user_id = ? AND ip_address IS NOT NULL AND ip_address <> ''", uid) do |rs|
            rs.read(String)
          end.each do |ip|
            conn.exec(
              "INSERT INTO bans (user_id, ip_address, created_at, updated_at) VALUES (?, ?, ?, ?)",
              uid, ip, now, now)
          end
          conn.exec("DELETE FROM sessions WHERE user_id = ?", uid)
          conn.exec("UPDATE users SET status = 2, updated_at = ? WHERE id = ?", now, uid)
        end
      end
      # apply_ban of the reference: close_remote_connections — tear the banned user's live
      # sockets AFTER commit (a socket closed too early reconnects and re-reads the still-live session).
      close_remote_connections
      Campfire::JobQueue.enqueue_batch([{"remove_banned_content", %({"user_id":#{uid}})}])
    end

    def unban : Nil
      uid = id.not_nil!
      now = Time.utc
      Campfire::WriteQueue.perform do
        conn = ActiveRecord::Base.connection
        conn.exec("DELETE FROM bans WHERE user_id = ?", uid)
        conn.exec("UPDATE users SET status = 0, updated_at = ? WHERE id = ?", now, uid)
      end
    end
  end
  include Bannable
end
