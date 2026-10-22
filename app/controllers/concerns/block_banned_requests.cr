# Порт once-campfire/app/controllers/concerns/block_banned_requests.rb:
# не-GET/HEAD запросы с IP из таблицы bans получают 429 — забаненный
# не может перерегистрироваться/логиниться, пока висит бан его IP.
module BlockBannedRequests
  private def reject_banned_ip : Nil
    return if safe_request?
    return unless (ip = remote_ip)
    banned = ActiveRecord::Base.connection.query_one?(
      "SELECT 1 FROM bans WHERE ip_address = ? LIMIT 1", ip, as: Int32)
    head(:too_many_requests) if banned
  end

  private def safe_request? : Bool
    {"GET", "HEAD"}.includes?(request.method)
  end
end
