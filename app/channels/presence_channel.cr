# PresenceChannel — присутствие в комнате (референс: presence_channel.rb
# + RoomChannel): подписка через membership, present/absent двигают
# connections/connected_at, refresh обновляет connected_at (presence_
# controller.js шлёт его каждые 50с, loadgen — по --refresh-secs).
class PresenceChannel < ApplicationCable::Channel
  def subscribed : Nil
    if (room_id = subscribable_room_id)
      stream_from("presence_channel:#{gid_param(room_id)}")
      mark_present(room_id)
      broadcast_read_room(room_id)
    else
      reject
    end
  end

  def unsubscribed : Nil
    if (room_id = subscribable_room_id)
      mark_absent(room_id)
    end
  end

  def refresh(data : Hash(String, String)) : Nil
    if (room_id = subscribable_room_id)
      conn = ActiveRecord::Base.connection
      conn.exec(
        "UPDATE memberships SET connected_at = ? WHERE room_id = ? AND user_id = ?",
        Time.utc, room_id, current_user_id)
    end
  end

  private def subscribable_room_id : Int64?
    uid = current_user_id
    return nil unless uid
    room_id = params["room_id"]?.try(&.to_i64?)
    return nil unless room_id

    Membership.where("room_id = ? AND user_id = ?", room_id, uid).take.try do |_m|
      room_id
    end
  end

  private def gid_param(room_id : Int64) : String
    Base64.urlsafe_encode("gid://campfire/Room/#{room_id}", padding: false)
  end

  private def mark_present(room_id : Int64) : Nil
    # Membership#present → connect (Connectable): connections растёт при
    # живой подписке в TTL (60с), иначе 1; подписка чистит unread_at.
    conn = ActiveRecord::Base.connection
    conn.exec(
      "UPDATE memberships SET connected_at = ?, unread_at = NULL, " \
      "connections = CASE WHEN connected_at >= ? THEN connections + 1 ELSE 1 END " \
      "WHERE room_id = ? AND user_id = ?",
      Time.utc, Time.utc - 60.seconds, room_id, current_user_id)
  end

  private def mark_absent(room_id : Int64) : Nil
    conn = ActiveRecord::Base.connection
    conn.exec(
      "UPDATE memberships SET connections = MAX(connections - 1, 0) WHERE room_id = ? AND user_id = ?",
      room_id, current_user_id)
  end

  private def broadcast_read_room(room_id : Int64) : Nil
    if (uid = current_user_id)
      ActionCable.server.broadcast("user_#{uid}_reads", {"room_id" => room_id})
    end
  end
end
