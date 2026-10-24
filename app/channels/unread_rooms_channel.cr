class UnreadRoomsChannel < ApplicationCable::Channel
  # Scoped per user, like ReadRoomsChannel. A single global stream would tell every
  # authenticated connection when any room on the account is active, including closed
  # rooms and direct conversations they're not part of.
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
