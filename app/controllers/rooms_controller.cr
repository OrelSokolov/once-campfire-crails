# GET /rooms/:id — страница комнаты (контракт: полная HTML-страница,
# data-message-id ровно 40 последних сообщений ASC, DOM-идентичности
# id="message_<id>" или id="<client_message_id>", тела сообщений).
class RoomsController < ApplicationController
  def show
    room = Room.find?(params["id"].to_s.to_i64)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end

    # Контракт: 40 последних по created_at DESC, вывод в ASC.
    messages = Message.where("room_id = ?", room.id.not_nil!)
      .order("created_at DESC").limit(40).to_a.reverse

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << "<!doctype html>\n<html>\n<head><title>"
      io << HTML.escape(room.name.to_s)
      io << %(</title>\n<link rel="stylesheet" href="/assets/application.css">\n</head>\n<body>\n)
      io << %(<main id="messages_room_#{room.id}">\n)
      messages.each do |m|
        cmid = m.client_message_id.to_s
        io << %(  <article id="message_#{m.id}" data-message-id="#{m.id}" data-client-message-id=")
        io << HTML.escape(cmid) << %("\n    >)
        io << %(<div class="message-body">) << m.body.to_s << "</div>\n"
        io << "  </article>\n"
      end
      io << "</main>\n</body>\n</html>\n"
    end)
  end
end
