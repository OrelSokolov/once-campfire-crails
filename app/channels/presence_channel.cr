require "./room_channel"

class PresenceChannel < RoomChannel
  on_subscribe :present, unless: :subscription_rejected?
  on_unsubscribe :absent, unless: :subscription_rejected?

  def present : Nil
    membership.try(&.present)

    # PRAGMA data_version of the pool does not see writes from this connection, so
    # invalidate the response cache explicitly (see notes/known-gaps.md).
    Campfire::ResponseCache.invalidate!

    broadcast_read_room
  end

  def absent : Nil
    membership.try(&.disconnected)
  end

  def refresh : Nil
    membership.try(&.refresh_connection)
  end

  private def membership : Membership?
    if (room = @room) && (uid = current_user_id)
      room.memberships.find_by(user_id: uid)
    end
  end

  private def broadcast_read_room : Nil
    if (m = membership) && (uid = current_user_id)
      ActionCable.server.broadcast("user_#{uid}_reads",
        {"room_id" => m.room_id, "at" => Time.utc.to_unix_f})
    end
  end
end
