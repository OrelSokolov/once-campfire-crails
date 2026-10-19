# GET / — корень: redirect в последнюю посещённую комнату (cookie
# last_room, если пользователь её видит), иначе — первая original-комната
# (семантика welcome#show + TrackedRoomVisit из Rails-референса).
# Если видимых комнат нет — welcome/show.html.erb: пустой message-area
# с иконкой и именем юзера для screen-reader (hi, Lonely Lou).
class WelcomeController < ApplicationController
  include WelcomeHelpers

  @user : User?
  attr_reader :user

  def show
    user = current_user.not_nil!
    @user = user

    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= default_room(user)

    if room
      redirect_to(room_path(room.id.not_nil!))
    end
  end

  # Current.user.rooms.original — первая original-комната; как fallback
  # берём первую видимую по id.
  private def default_room(user : User) : Room?
    Room.visible_for(user).order("id").first?
  end

end
