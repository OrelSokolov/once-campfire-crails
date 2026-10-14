# GET /users/me/sidebar — сайдбар со списком комнат (контракт: полная
# HTML-страница, содержит "shared_rooms" и все видимые имена комнат).
class SidebarsController < ApplicationController
  def show
    user = current_user.not_nil!

    # Whole-page response cache (как rooms#show): список комнат меняется
    # только write'ами (rooms create/update, MessageCreator) — все сбрасывают
    # PageCache.invalidate!, так что epoch гарантирует свежесть.
    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key("sidebars#show", request, user.id)
    if (cached = PageCache.get(key, epoch))
      return send_page(cached)
    end

    rooms = Room.visible_for(user).order("id").to_a

    # turbo_stream_from :rooms + turbo_stream_from Current.user, :rooms
    # (референс: users/sidebars/show.html.erb; loadgen scrape собирает
    # источники и с room-страницы, и с сайдбара).
    rooms_stream = Turbo::Streams::StreamName.signed_stream_name(["rooms"])
    user_rooms_stream = Turbo::Streams::StreamName.signed_stream_name([user, "rooms"])

    # Подписи direct-чатов одним JOIN-запросом (было N+1: SELECT
    # участников на каждую direct-комнату).
    labels = direct_labels(rooms, user)

    html = String.build do |io|
      io << "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n"
      io << %(<turbo-frame id="user_sidebar">\n)
      io << %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name=")
      io << HTML.escape(rooms_stream) << %(" data-turbo-stream-source="Turbo::StreamsChannel"></turbo-cable-stream-source>\n)
      io << %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name=")
      io << HTML.escape(user_rooms_stream) << %(" data-turbo-stream-source="Turbo::StreamsChannel"></turbo-cable-stream-source>\n)
      io << %(<nav class="sidebar">\n  <div id="shared_rooms" class="shared_rooms">\n)
      rooms.each do |r|
        next if r.name.nil? # direct rooms render member names, not room names
        kind = r.type.to_s.split("::").last?.try(&.downcase)
        io << %(    <a id="list_rooms_#{kind}_#{r.id}" href="/rooms/#{r.id}" class="room room_#{r.type.to_s.downcase.gsub("::", "_")}">)
        io << %(<span class="overflow-ellipsis">)
        io << HTML.escape(r.name.to_s) << "</span></a>\n"
      end
      io << "  </div>\n"

      # direct_rooms_control (sidebar.eta): New Ping + список direct-чатов
      # (sidebar_direct: for-screen-reader "Ping with" + Label из имён).
      io << %(<turbo-frame id="direct_rooms_control" target="_top">)
      io << %(<div class="directs gap overflow-x overflow-hide-scrollbar">)
      io << %(<a class="direct direct__new" data-turbo-frame="_self" href="/rooms/directs/new">)
      io << %(<span class="direct__author flex max-width min-width border-radius pad-inline-half">)
      io << %(<span class="for-screen-reader">New</span>)
      io << %(<span class="txt-small overflow-clip">Ping</span></span></a>\n)
      io << %(<div id="direct_rooms">\n)
      rooms.each do |r|
        next unless r.name.nil?
        label = labels[r.id.not_nil!]? || ""
        io << %(  <a class="direct" id="list_rooms_direct_#{r.id}" data-room-id="#{r.id}" )
        io << %(href="/rooms/#{r.id}">)
        io << %(<span class="direct__author flex align-center gap max-width min-width border-radius txt-small">)
        io << %(<span class="txt-nowrap overflow-ellipsis">)
        io << %(<span class="for-screen-reader">Ping with</span>) << HTML.escape(label)
        io << %(</span></span></a>\n)
      end
      io << %(</div></div></turbo-frame>\n)
      io << "</nav>\n</turbo-frame>\n</body>\n</html>\n"
    end

    page = Campfire::PageCache::Page.new(html)
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end

  # room_id → "Имя1, Имя2" по первым словам имён участников direct-чата
  # кроме viewer'а, участники в порядке id (как референс: User.where(...)
  # .order("id") на каждую комнату — здесь один запрос на все).
  private def direct_labels(rooms : Array(Room), user : User) : Hash(Int64, String)
    direct_ids = rooms.select(&.name.nil?).map(&.id.not_nil!)
    labels = {} of Int64 => String
    return labels if direct_ids.empty?
    placeholders = direct_ids.map { "?" }.join(", ")
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT mm.room_id, u.id, u.name FROM memberships mm
        JOIN users u ON u.id = mm.user_id
        WHERE mm.room_id IN (#{placeholders}) ORDER BY u.id),
      args: direct_ids, as: {Int64, Int64, String})
    members = Hash(Int64, Array({Int64, String})).new do |h, k|
      h[k] = [] of {Int64, String}
    end
    rows.each { |(room_id, uid, name)| members[room_id] << {uid, name} }
    members.each do |room_id, list|
      labels[room_id] = list.reject { |uid, _| uid == user.id.not_nil! }
        .map { |_, name| name.split(" ")[0]? || "" }.join(", ")
    end
    labels
  end
end
