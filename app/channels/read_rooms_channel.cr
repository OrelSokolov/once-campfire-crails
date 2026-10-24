class ReadRoomsChannel < ApplicationCable::Channel
  def subscribed : Nil
    if (uid = current_user_id)
      stream_from("user_#{uid}_reads")
    else
      reject
    end
  end
end
