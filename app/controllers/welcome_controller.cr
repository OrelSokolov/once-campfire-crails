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

  # The reference's Current.user.rooms.original — the first original room; we fall
  # back to the first visible room by id.
  private def default_room(user : User) : Room?
    Room.visible_for(user).order("id").first?
  end

end
