# GET / — корень: redirect в последнюю посещённую комнату (cookie
# last_room, если пользователь её видит), иначе — первая original-комната
# (семантика welcome#show + TrackedRoomVisit из Rails-референса).
# Если видимых комнат нет — welcome/show.html.erb: пустой message-area
# с иконкой и именем юзера для screen-reader (hi, Lonely Lou).
class WelcomeController < ApplicationController
  @user : User?

  def show
    user = current_user.not_nil!
    @user = user

    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= default_room(user)

    if room
      redirect_to("/rooms/#{room.id.not_nil!}")
    end
  end

  # Current.user.rooms.original — первая original-комната; как fallback
  # берём первую видимую по id.
  private def default_room(user : User) : Room?
    Room.visible_for(user).order("id").first?
  end

  # ————— ERB-хелперы (app/views/welcome/show.html.erb) —————

  # «No rooms yet»: head для пустого message-area-экрана (chat: false).
  private def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("No rooms yet", @user.not_nil!, nil, chat: false))
  end

  private def messages_empty_src : String
    ChatLayout.asset("messages-empty.svg")
  end

  private def campfire_icon_src : String
    ChatLayout.asset("campfire-icon.png")
  end
end
