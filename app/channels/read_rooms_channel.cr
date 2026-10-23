# ReadRoomsChannel (read_rooms_channel.rb оракула): стрим уведомлений
# «прочитано» для пользователя (broadcast — PresenceChannel).
class ReadRoomsChannel < ApplicationCable::Channel
  def subscribed : Nil
    if (uid = current_user_id)
      stream_from("user_#{uid}_reads")
    else
      reject
    end
  end
end
