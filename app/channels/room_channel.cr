# RoomChannel (room_channel.rb оракула): база каналов комнаты —
# подписка только на комнату с membership текущего пользователя.
class RoomChannel < ApplicationCable::Channel
  def subscribed : Nil
    if (@room = find_room)
      stream_for(@room.not_nil!)
    else
      reject
    end
  end

  protected def room : Room?
    @room
  end

  # current_user.rooms.find_by(id: params[:room_id]) — membership
  # проверяется по строковому connection-identifier.
  private def find_room : Room?
    uid = current_user_id
    return nil unless uid
    room_id = params["room_id"]?.try(&.to_i64?)
    return nil unless room_id

    if Membership.where("room_id = ? AND user_id = ?", room_id, uid).exists?
      Room.find?(room_id)
    end
  end

  @room : Room?
end
