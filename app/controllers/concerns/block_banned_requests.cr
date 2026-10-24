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
