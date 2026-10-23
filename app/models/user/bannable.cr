require "../application_record"

# User::Bannable (user/bannable.rb): бан/разбан — bans из IP-сессий,
# разлогин, статус banned; контент удаляет RemoveBannedContentJob.
class User
  module Bannable
    # User::Bannable#ban (контракт express routes.js): транзакция —
    # bans из IP-адресов сессий юзера (DISTINCT, без пустых), удаление
    # сессий (разлогин), статус banned (2). Контент удаляется
    # асинхронно джобой remove_banned_content — постановка строго
    # после commit, как notify в MessageCreator.
    def ban : Nil
      uid = id.not_nil!
      now = Time.utc
      Campfire::WriteQueue.perform do
        ActiveRecord::Base.transaction do
          conn = ActiveRecord::Base.__session # pinned-коннект транзакции
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
      # apply_ban референса: close_remote_connections — рвём live-сокеты
      # забаненного ПОСЛЕ commit (рано закрытый сокет реконнектится и
      # перечитает ещё живую сессию).
      close_remote_connections
      Campfire::JobQueue.enqueue_batch([{"remove_banned_content", %({"user_id":#{uid}})}])
    end

    # User::Bannable#unban: bans.delete_all + active! (статус 0).
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
