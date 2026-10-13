# UnreadRoomsChannel — непрочитанные комнаты текущего пользователя
# (референс: unread_rooms_channel.rb): стрим per-user.
class UnreadRoomsChannel < ApplicationCable::Channel
  def self.stream_name_for(user_id : String) : String
    "user_#{user_id}_unreads"
  end

  def subscribed : Nil
    if (uid = current_user_id)
      stream_from(self.class.stream_name_for(uid))
    else
      reject
    end
  end
end
