# GET /searches?q=coffee — поиск по FTS5 (контракт: ID = MATCH с join по
# membership/email из сида, максимум 100, вывод в порядке ID). Разметка —
# app/views/searches/show.html.erb (референс: searches/index.html.erb;
# имя — по экшену порта, см. config/routes.cr).
class SearchesController < ApplicationController
  include SearchesHelpers

  # show.html.erb: запрос, выдача (FTS5), недавние запросы, DB-epoch
  # (ERB-хелперы SearchesHelpers читают их через геттеры);
  # @return_room — комната возврата (composer, читается шаблоном напрямую).
  getter user : User? = nil
  getter query : String = ""
  getter messages : Array(Message) = [] of Message
  getter recents : Array(String) = [] of String
  getter epoch : String = ""
  @return_room : Int64 = 1_i64

  # HTML-партиалы nav поиска (search_nav.eta/recent_searches.eta): чип
  # запроса + recents; рендерятся обёртками SearchesHelpers#search_nav и
  # #recent_searches_html (второй используется и в page_close — aside).
  compile_partials({
    "searches/nav" => {path: "app/views/searches/_nav.html.erb",
                       locals: {"query" => String, "count" => Int32,
                                "recents" => Array(String)}},
    "searches/recent_searches" => {path: "app/views/searches/_recent_searches.html.erb",
                                   locals: {"recents" => Array(String)}},
  }, dedent: true)

  def show
    user = current_user.not_nil!

    # Whole-page response cache (как rooms#show): ключ включает query
    # (?q=...), инвалидация — общий DB-epoch (FTS-индекс и сообщения
    # меняются только write'ами, все сбрасывают PageCache.invalidate!).
    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key("searches#show", request, user.id)
    if (cached = PageCache.get(key, epoch))
      return send_page(cached)
    end

    query = params["q"]?.to_s.strip

    messages = if query.empty?
      [] of Message
    else
      # Same shape as the harness's seed SQL: messages visible to the user,
      # newest 100 matches by id, displayed in id order.
      Message.where(
        %(id IN (SELECT m.id FROM messages m
                 JOIN message_search_index idx ON idx.rowid = m.id
                 JOIN memberships mm ON mm.room_id = m.room_id
                 WHERE mm.user_id = ? AND message_search_index MATCH ?
                 ORDER BY m.id DESC LIMIT 100)),
        user.id.not_nil!, query)
        .order("id ASC").to_a
    end

    # Recent searches (search.eta/search_nav.eta): 10 последних запросов.
    recents = ActiveRecord::Base.connection.query_all(
      "SELECT query FROM searches WHERE user_id = ? ORDER BY updated_at DESC LIMIT 10",
      args: [user.id.not_nil!], as: String)

    # Комната возврата (composer в show.html.erb: стрелка «Exit search»).
    return_room = (user.memberships.map(&.room_id.not_nil!).min? ||
                  Room.visible_for(user).order("id").first.try(&.id.not_nil!) || 1).to_i64

    # Список — через fragment-кэш (было Room.find?/User.find?/rich_text
    # на каждое сообщение, до 100 результатов): хиты без SQL, комнаты и
    # авторы промахов — по одному IN-запросу на сущность.
    @user = user
    @query = query
    @messages = messages
    @recents = recents
    @return_room = return_room
    @epoch = epoch

    page = Campfire::PageCache::Page.new(__render_view("show").to_s)
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end

  # POST /searches — записать запрос в recents и перейти к выдаче
  # (routes.js: touch search + redirect /searches?q=...).
  def create
    user = current_user.not_nil!
    query = params["q"]?.to_s.strip
    unless query.empty?
      now = Time.utc
      Search.new(user_id: user.id.not_nil!, query: query,
        created_at: now, updated_at: now).save!
      Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    end
    redirect_to "/searches?q=" + URI.encode_www_form(query)
  end

  # DELETE /searches/clear — очистить recents пользователя.
  def clear
    user = current_user.not_nil!
    ActiveRecord::Base.connection.exec(
      "DELETE FROM searches WHERE user_id = ?", user.id.not_nil!)
    Campfire::PageCache.invalidate!
    redirect_to "/searches"
  end
end
