class Rooms::RefreshesController < ApplicationController
  @room : Room?
  @new_messages : Array(Message) = [] of Message
  @updated_messages : Array(Message) = [] of Message
  include RoomsHelper

  def show
    room = current_user.not_nil!.rooms.find?(params["id"].to_s)
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!

    since = Time.unix_ms(params["since"]?.try(&.to_s.to_i64?) || 0_i64)

    @room = room
    new_messages = Message::Pagination.page_created_since(room, since)

    new_ids = Set.new(new_messages.map(&.id.not_nil!))
    @new_messages = new_messages
    @updated_messages = Message::Pagination.page_updated_since(room, since)
      .reject { |m| new_ids.includes?(m.id.not_nil!) }

    render(html: __render_view("show", format: "turbo_stream").to_s,
      content_type: "text/vnd.turbo-stream.html")
  end
end
