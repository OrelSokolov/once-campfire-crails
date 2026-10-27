module CachedResponses
  @db_epoch : String? = nil

  # Memoized for the duration of the request so authentication and the page
  # cache observe a single PRAGMA data_version read.
  def db_epoch : String
    @db_epoch ||= PageCache.epoch
  end

  # Oracle's CachedResponses#read_record_cache_version: the version handed to
  # RecordCache — read requests only (GET/HEAD).
  def read_record_cache_version : String?
    db_epoch if {"GET", "HEAD"}.includes?(request.method)
  end

  def cache_page(name : String, user_id : Int64?, & : -> Campfire::ResponseCache::Page) : Campfire::ResponseCache::Page
    epoch = db_epoch
    key = PageCache.key(name, request, user_id)
    if (cached = PageCache.get(key, epoch))
      return cached
    end
    page = yield
    # Store only when the DB epoch is unchanged and no Set-Cookie was emitted,
    # so readers holding an older epoch never observe a fresher page.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    page
  end

  def send_page(page : Campfire::ResponseCache::Page) : Nil
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    response.headers["ETag"] = page.etag
    response.headers["Cache-Control"] = "no-cache"
    if request.headers["If-None-Match"]? == page.etag
      # render(plain:) resets the status, so pass it as an argument.
      return render(plain: "", status: :not_modified)
    end
    # Bodies are raw bytes: a gzip payload need not be valid UTF-8, and the
    # renderer writes the bytes as-is.
    if request.headers["Accept-Encoding"]?.to_s.includes?("gzip")
      response.headers["Content-Encoding"] = "gzip"
      response.headers["Vary"] = "Accept-Encoding"
      render(html: page.gzip)
    else
      render(html: page.bytes)
    end
  end
end
