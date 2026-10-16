# GET /searches?q=coffee — поиск по FTS5 (контракт: ID = MATCH с join по
# membership/email из сида, максимум 100, вывод в порядке ID).
class SearchesController < ApplicationController
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

    # Комната возврата (search_composer: стрелка «Exit search»).
    return_room = (user.memberships.map(&.room_id.not_nil!).min? ||
                  Room.visible_for(user).order("id").first.try(&.id.not_nil!) || 1).to_i64

    # Список — через fragment-кэш (было Room.find?/User.find?/rich_text
    # на каждое сообщение, до 100 результатов): хиты без SQL, комнаты и
    # авторы промахов — по одному IN-запросу на сущность.
    html = String.build do |io|
      io << ChatLayout.page_open("search", "Search: #{query}", user,
        body_class: "sidebar searches", nav_html: search_nav(query, messages.size, recents))
      io << %(<div id="message-area" class="message-area">\n)
      io << %(<div class="message-area--empty min-width center"><figure class="center pad">)
      io << %(<img aria-hidden="true" class="colorize--black translucent" src=")
      io << ChatLayout.asset("search.svg") << %("></figure></div>\n)
      io << %(<div id="search-results" class="messages searches__results" data-controller="search-results" )
      io << %(data-search-results-target="messages" data-search-results-me-class="message--me" )
      io << %(data-search-results-threaded-class="message--threaded" )
      io << %(data-search-results-mentioned-class="message--mentioned" )
      io << %(data-search-results-formatted-class="message--formatted" data-query=") << HTML.escape(query) << %(">\n)
      ChatLayout.messages_to(io, messages, epoch, nil, origin)
      io << %(</div>\n)
      io << %(</div>\n)
      io << ChatLayout.page_close(search_composer(query, return_room),
        %(<div class="rooms position-relative flex flex-column gap overflow-y overflow-hide-scrollbar">) + recent_searches_html(recents) + %(</div>))
    end

    page = Campfire::PageCache::Page.new(html)
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

  # search_nav.eta: чип запроса с количеством + recents.
  private def search_nav(query : String, count : Int32, recents : Array(String)) : String
    String.build do |io|
      unless query.empty?
        io << %(<div class="searches__query flex align-center gap pad-block-start-half">)
        io << %(<div class="btn btn--reversed btn--faux align-center gap txt-nowrap">)
        io << %(<span class="overflow-ellipsis">“) << HTML.escape(query) << %(”</span>)
        io << %(<span class="flex-item-no-shrink">) << count << %(</span></div></div>)
      end
      io << %(<div class="searches__recents align-center gap pad-block-half overflow-y overflow-hide-scrollbar">)
      io << recent_searches_html(recents)
      io << %(</div>)
    end
  end

  # recent_searches.eta: ссылки на последние запросы + очистка (broom).
  private def recent_searches_html(recents : Array(String)) : String
    String.build do |io|
      recents.each do |q|
        io << %(<a class="align-center gap room btn txt-nowrap" href="/searches?q=)
        io << URI.encode_www_form(q) << %("><span class="overflow-ellipsis">“)
        io << HTML.escape(q) << %(”</span></a>)
      end
      unless recents.empty?
        io << %(<form class="button_to" method="post" action="/searches/clear">)
        io << %(<input type="hidden" name="_method" value="delete">)
        io << %(<button class="btn searches__btn" )
        io << %(data-turbo-confirm="Are you sure you want to clear your recent searches?" )
        io << %(type="submit">) << ChatLayout.icon("broom.svg")
        io << %(<span class="for-screen-reader">Clear recent searches</span></button></form>)
      end
    end
  end

  # search_composer.eta: выход из поиска (стрелка) + поле с иконками.
  private def search_composer(query : String, return_room : Int64) : String
    String.build do |io|
      io << %(<div class="composer flex align-end gap">)
      io << %(<a class="btn flex-item-no-shrink margin-block-end" )
      io << %(style="view-transition-name: input-switcher; --btn-border-radius: 0.5em" )
      io << %(href="/rooms/) << return_room << %(">)
      io << ChatLayout.icon("arrow-left.svg")
      io << %(<span class="for-screen-reader">Exit search</span></a>)
      io << %(<form class="margin-block flex-item-grow contain flex align-center gap" )
      io << %(data-controller="form" data-action="keydown.esc-&gt;form#cancel" )
      io << %(action="/searches" accept-charset="UTF-8" method="post">)
      io << %(<div class="composer__input flex align-center flex-item-grow gap full-width input input--actor min-width">)
      io << %(<img aria-hidden="true" class="composer__input-hint colorize--black" )
      io << %(style="view-transition-name: input-btn" src=")
      io << ChatLayout.asset("search.svg") << %(" width="20" height="20">)
      io << %(<input value=") << HTML.escape(query)
      io << %(" class="searches__input input flex-item-grow" role="searchbox" aria-label="search" )
      io << %(autofocus required type="text" name="q" id="q">)
      io << %(<a data-form-target="cancel" role="button" class="searches__reset" href="/searches">)
      io << ChatLayout.icon("remove.svg", 14, "colorize--black")
      io << %(<span class="for-screen-reader">Clear search field</span></a>)
      io << %(<button name="button" type="submit" class="btn btn--reversed flex-item-no-shrink txt-small" )
      io << %(style="--btn-border-radius: 0.5em">) << ChatLayout.icon("arrow-up.svg")
      io << %(<span class="for-screen-reader">Search</span></button></div></form></div>)
    end
  end
end
