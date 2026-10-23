require "./room_channel"
# PresenceChannel — присутствие в комнате (presence_channel.rb оракула,
# база RoomChannel): подписка через membership, present/absent двигают
# connections/connected_at (Membership::Connectable), refresh обновляет
# connected_at (presence_controller.js шлёт его каждые 50с, loadgen — по
# --refresh-secs).
class PresenceChannel < RoomChannel
  def subscribed : Nil
    if (@room = find_room)
      stream_from("presence_channel:#{gid_param(@room.not_nil!.id.not_nil!)}")
      mark_present(@room.not_nil!.id.not_nil!)
      broadcast_read_room(@room.not_nil!.id.not_nil!)
    else
      reject
    end
  end

  def unsubscribed : Nil
    if (room = @room)
      mark_absent(room.id.not_nil!)
    end
  end

  def refresh(data : Hash(String, String)) : Nil
    if (room = @room) && (uid = current_user_id)
      Membership::Connectable.refresh_connection(room.id.not_nil!, uid)
    end
  end

  private def gid_param(room_id : Int64) : String
    Base64.urlsafe_encode("gid://campfire/Room/#{room_id}", padding: false)
  end

  private def mark_present(room_id : Int64) : Nil
    Membership::Connectable.connect(room_id, current_user_id.not_nil!)
    # Чистка unread_at меняет сайдбар/rooms#show, но пишем из своего
    # соединения — PRAGMA data_version пула этого не видит (инвалидация
    # только на чужие коммиты), поэтому сбрасываем ResponseCache явно.
    Campfire::ResponseCache.invalidate!
  end

  private def mark_absent(room_id : Int64) : Nil
    if (uid = current_user_id)
      Membership::Connectable.disconnect(room_id, uid)
    end
  end

  private def broadcast_read_room(room_id : Int64) : Nil
    if (uid = current_user_id)
      ActionCable.server.broadcast("user_#{uid}_reads",
        {"room_id" => room_id, "at" => Time.utc.to_unix_f})
    end
  end
end
