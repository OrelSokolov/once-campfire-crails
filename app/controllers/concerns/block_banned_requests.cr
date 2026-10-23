# Порт once-campfire/app/controllers/concerns/block_banned_requests.rb:
# не-GET/HEAD запросы с IP из таблицы bans получают 429 — забаненный
# не может перерегистрироваться/логиниться, пока висит бан его IP.
module BlockBannedRequests
  private def reject_banned_ip : Nil
    return if safe_request?
    return unless (ip = remote_ip)
    head(:too_many_requests) if Ban.banned?(ip)
  end

  private def safe_request? : Bool
    {"GET", "HEAD"}.includes?(request.method)
  end
end
