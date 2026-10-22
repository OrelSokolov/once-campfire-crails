# GET/PUT /rooms/:id/involvement — turbo-frame колокольчика вовлечённости
# (референс: rooms/involvements_controller.rb + rooms/involvements/
# show.html.erb): show — текущее состояние, update — смена (цикл
# RoomsHelper#next_involvement_for) + редирект на show фрейма.
class Rooms::InvolvementsController < ApplicationController
  # show.html.erb (_bell.html.erb — кнопка button_to PUT со следующим
  # состоянием вовлечённости): комната + membership текущего пользователя.
  def show
    if (membership = current_membership)
      involvement = membership.involvement.to_s.presence || "mentions"
      response.headers["Content-Type"] = "text/html; charset=utf-8"
      render(html: ChatERB.new(room: membership_room(membership),
        involvement: involvement, origin: origin).involvement_show.to_s)
    else
      render_room_not_found
    end
  end

  # PUT /rooms/:id/involvement — смена вовлечённости, редирект на show.
  def update
    if (membership = current_membership)
      value = params["involvement"].to_s
      if %w[mentions everything nothing invisible].includes?(value)
        membership.update({"involvement" => value})
      end
      redirect_to room_involvement_url(membership.room_id.not_nil!)
    else
      render_room_not_found
    end
  end

  # RoomScoped референса: membership текущего пользователя в комнате
  # (:id роута) — границы доступа, как у RoomsController#set_room.
  private def current_membership : Membership?
    room_id = params["id"].to_s.to_i64?
    return nil unless room_id
    if (user = current_user) &&
       (room = Room.find?(room_id))
      Membership.where(
        "room_id = ? AND user_id = ?", room.id.not_nil!, user.id.not_nil!).take
    end
  end

  private def membership_room(membership : Membership) : Room
    Room.find?(membership.room_id.not_nil!).not_nil!
  end

  private def render_room_not_found : Nil
    response.status = :not_found
    render(plain: "Room not found")
  end
end
