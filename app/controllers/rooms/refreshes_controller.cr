# GET /rooms/:id/refresh — turbo-stream опрос refresh-room-контроллера
# (референс: rooms/refreshes_controller.rb): сообщения, созданные после
# since, — append в контейнер сообщений; обновлённые (кроме новых) —
# replace по dom_id. Разметка — refresh_stream (RoomsHelper).
class Rooms::RefreshesController < ApplicationController
  @room : Room?
  @new_messages : Array(Message) = [] of Message
  @updated_messages : Array(Message) = [] of Message
  include RoomsHelper

  def show
    # Rooms::RefreshesController оракула включает RoomScoped: комната —
    # только внутри членства текущего юзера (иначе /rooms/:id/refresh
    # отдаёт turbo-stream с чужой историей, включая DM).
    room = Room.where(
      "id IN (SELECT room_id FROM memberships WHERE user_id = ?)",
      current_user.not_nil!.id.not_nil!)
      .where(id: params["id"].to_s.to_i64).first
    unless room
      response.status = :not_found
      return render(plain: "Room not found")
    end
    room = room.not_nil!

    # since — мс-эпоха (refresh_room_controller: loaded-at / message
    # updated-at), пустое/невалидное — Time.at(0).
    since = Time.unix_ms(params["since"]?.try(&.to_s.to_i64?) || 0_i64)

    # page_created_since: первая страница (40 ASC).
    @room = room
    new_messages = Message::Pagination.page_created_since(room, since)

    # page_updated_since + without(new): последняя страница сортировки
    # по created_at, минус новые.
    new_ids = Set.new(new_messages.map(&.id.not_nil!))
    @new_messages = new_messages
    @updated_messages = Message::Pagination.page_updated_since(room, since)
      .reject { |m| new_ids.includes?(m.id.not_nil!) }

    render(html: __render_view("show", format: "turbo_stream").to_s,
      content_type: "text/vnd.turbo-stream.html")
  end
end
