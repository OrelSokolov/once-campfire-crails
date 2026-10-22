# GET /rooms/:id/refresh — turbo-stream опрос refresh-room-контроллера
# (референс: rooms/refreshes_controller.rb): сообщения, созданные после
# since, — append в контейнер сообщений; обновлённые (кроме новых) —
# replace по dom_id. Разметка — refresh_stream (RoomsHelpers).
class Rooms::RefreshesController < ApplicationController
  include RoomsHelpers

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

    # page_created_since: created_at > since, первая страница (40 ASC).
    new_messages = Message.where(
      "room_id = ? AND created_at > ?", room.id.not_nil!, since)
      .order("created_at ASC").limit(40).to_a

    # page_updated_since + without(new): updated_at > since, последняя
    # страница сортировки по created_at (DESC limit 40 → ASC), минус новые.
    new_ids = Set.new(new_messages.map(&.id.not_nil!))
    updated_messages = Message.where(
      "room_id = ? AND updated_at > ?", room.id.not_nil!, since)
      .order("created_at DESC").limit(40).to_a.reverse
      .reject { |m| new_ids.includes?(m.id.not_nil!) }

    render(html: refresh_stream(room, new_messages, updated_messages),
      content_type: "text/vnd.turbo-stream.html")
  end
end
