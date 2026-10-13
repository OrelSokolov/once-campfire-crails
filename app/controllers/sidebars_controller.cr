# GET /users/me/sidebar — сайдбар со списком комнат (контракт: полная
# HTML-страница, содержит "shared_rooms" и все видимые имена комнат).
class SidebarsController < ApplicationController
  def show
    user = current_user.not_nil!
    rooms = Room.visible_for(user).order("id").to_a

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n"
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
