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
      io << %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name=")
      io << HTML.escape(rooms_stream) << %(" data-turbo-stream-source="Turbo::StreamsChannel"></turbo-cable-stream-source>\n)
      io << %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name=")
      io << HTML.escape(user_rooms_stream) << %(" data-turbo-stream-source="Turbo::StreamsChannel"></turbo-cable-stream-source>\n)
      io << %(<nav class="sidebar">\n  <div class="shared_rooms">\n)
      rooms.each do |r|
        next if r.name.nil? # direct rooms render member names, not room names
        io << %(    <a href="/rooms/#{r.id}" class="room room_#{r.type.to_s.downcase.gsub("::", "_")}">)
        io << HTML.escape(r.name.to_s) << "</a>\n"
      end
      io << "  </div>\n</nav>\n</body>\n</html>\n"
    end)
  end
end
