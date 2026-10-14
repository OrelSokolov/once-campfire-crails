# GET /users/me/sidebar — сайдбар со списком комнат (контракт: полная
# HTML-страница, содержит "shared_rooms" и все видимые имена комнат).
class SidebarsController < ApplicationController
  def show
    user = current_user.not_nil!
    rooms = Room.visible_for(user).order("id").to_a

    # turbo_stream_from :rooms + turbo_stream_from Current.user, :rooms
    # (референс: users/sidebars/show.html.erb; loadgen scrape собирает
    # источники и с room-страницы, и с сайдбара).
    rooms_stream = Turbo::Streams::StreamName.signed_stream_name(["rooms"])
    user_rooms_stream = Turbo::Streams::StreamName.signed_stream_name([user, "rooms"])

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
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
        members = User.where(
          %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), r.id.not_nil!)
          .order("id").to_a.reject { |m| m.id == user.id }
        label = members.map { |m| m.name.to_s.split(" ")[0]? || "" }.join(", ")
        io << %(  <a class="direct" id="list_rooms_direct_#{r.id}" data-room-id="#{r.id}" )
        io << %(href="/rooms/#{r.id}">)
        io << %(<span class="direct__author flex align-center gap max-width min-width border-radius txt-small">)
        io << %(<span class="txt-nowrap overflow-ellipsis">)
        io << %(<span class="for-screen-reader">Ping with</span>) << HTML.escape(label)
        io << %(</span></span></a>\n)
      end
      io << %(</div></div></turbo-frame>\n)
      io << "</nav>\n</turbo-frame>\n</body>\n</html>\n"
    end)
  end
end
