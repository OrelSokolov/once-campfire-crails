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

    # Комнаты и авторы — по одному IN-запросу на сущность (было N+1:
    # Room.find? + User.find? на каждое сообщение, до 100 результатов).
    room_by_id = {} of Int64 => Room
    room_ids = messages.map(&.room_id.not_nil!).uniq
    unless room_ids.empty?
      Room.where(id: room_ids).each { |r| room_by_id[r.id.not_nil!] = r }
    end
    user_by_id = {} of Int64 => User
    creator_ids = messages.map(&.creator_id.not_nil!).uniq
    unless creator_ids.empty?
      User.where(id: creator_ids).each { |u| user_by_id[u.id.not_nil!] = u }
    end

    html = String.build do |io|
      io << ChatLayout.head("Search: #{query}", user, nil, chat: false)
      io << %(<body class="search">\n<main id="main-content">\n)
      io << %(<div id="search-results" class="messages searches__results" data-controller="search-results" )
      io << %(data-search-results-target="messages" data-search-results-me-class="message--me" )
      io << %(data-search-results-threaded-class="message--threaded" )
      io << %(data-search-results-mentioned-class="message--mentioned" )
      io << %(data-search-results-formatted-class="message--formatted" data-query=") << HTML.escape(query) << %(">\n)
      messages.each do |m|
        room = room_by_id[m.room_id.not_nil!]?
        next unless room
        io << ChatLayout.message_dom(m, room, user_by_id[m.creator_id.not_nil!]?)
      end
      io << %(</div>\n)
      io << %(</main>\n</body>\n</html>\n)
    end

    page = Campfire::PageCache::Page.new(html)
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end
end
