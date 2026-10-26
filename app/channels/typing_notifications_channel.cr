require "./room_channel"

class TypingNotificationsChannel < RoomChannel
  def start(data : Hash(String, String)) : Nil
    broadcast_to room.not_nil!, action: :start, user: current_user_attributes
  end

  def stop(data : Hash(String, String)) : Nil
    broadcast_to room.not_nil!, action: :stop, user: current_user_attributes
  end

  private def current_user_attributes
    current_user!.slice(:id, :name)
  end
end
