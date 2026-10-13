# GET / — корень: redirect в последнюю посещённую комнату (cookie
# last_room, если пользователь её видит), иначе — первая original-комната
# (семантика welcome#show + TrackedRoomVisit из Rails-референса).
class WelcomeController < ApplicationController
  def show
    user = current_user.not_nil!

    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= default_room(user)

    if room
      redirect_to("/rooms/#{room.id.not_nil!}")
    else
      render(plain: "Welcome to Campfire", status: 200)
    end
  end

  # Current.user.rooms.original — первая original-комната; как fallback
  # берём первую видимую по id.
  private def default_room(user : User) : Room?
    Room.visible_for(user).order("id").first?
  end
end
