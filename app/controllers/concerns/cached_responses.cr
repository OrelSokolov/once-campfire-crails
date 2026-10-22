# concerns/cached_responses.rb референса (response_cache.rb): whole-page
# response cache — готовый HTML кэшируется per-worker, инвалидация по
# DB-epoch (PRAGMA data_version); отдача с gzip + ETag/304.
module CachedResponses
  @db_epoch : String? = nil

  # DB-epoch запроса (PRAGMA data_version, см. PageCache): мемо на время
  # запроса — аутентификация и page-cache видят одну эпоху, PRAGMA
  # выполняется один раз.
  def db_epoch : String
    @db_epoch ||= PageCache.epoch
  end

  # Whole-page response cache (аналог around_action :cache_read_response
  # референса): hit → закэшированная страница; иначе блок строит Page, сет —
  # только если БД не менялась за время рендера и ответ чист (200, без
  # Set-Cookie) — иначе старые чтения получат новый epoch. Вызывающий делает
  # hit-специфичную работу (rooms#show: last_room-cookie) между cache_page
  # и send_page — на hit и miss одинаково.
  def cache_page(name : String, user_id : Int64?, & : -> Campfire::PageCache::Page) : Campfire::PageCache::Page
    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key(name, request, user_id)
    if (cached = PageCache.get(key, epoch))
      return cached
    end
    page = yield
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    page
  end

  # Отдача кэшированной страницы: If-None-Match → 304; Accept-Encoding
  # gzip → сжатое представление (лениво, живёт в Page). Тело — сырые
  # байты (gzip-строка может быть невалидным UTF-8 — Crystal пишет
  # байты как есть).
  def send_page(page : Campfire::PageCache::Page) : Nil
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    response.headers["ETag"] = page.etag
    response.headers["Cache-Control"] = "no-cache"
    if request.headers["If-None-Match"]? == page.etag
      # render(plain:) сбрасывает статус — передаём аргументом
      return render(plain: "", status: :not_modified)
    end
    if request.headers["Accept-Encoding"]?.to_s.includes?("gzip")
      response.headers["Content-Encoding"] = "gzip"
      response.headers["Vary"] = "Accept-Encoding"
      render(html: page.gzip)
    else
      render(html: page.bytes)
    end
  end
end
