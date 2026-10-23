require "./room_channel"
# TypingNotificationsChannel (typing_notifications_channel.rb
# оракула): start/stop набора текста — broadcast в стрим комнаты.
# Клиент (typing_notifications_controller.js + typing_tracker.js)
# уже портирован и ждёт {action, user:{id,name}}.
class TypingNotificationsChannel < RoomChannel
  def start(data : Hash(String, String)) : Nil
    broadcast_typing("start")
  end

  def stop(data : Hash(String, String)) : Nil
    broadcast_typing("stop")
  end

  private def broadcast_typing(action : String) : Nil
    return unless (r = room) && (uid = current_user_id)
    user = uid.to_i64?.try { |id| User.find?(id) }
    return unless user
    payload = JSON.build do |j|
      j.object do
        j.field "action", action
        j.field "user" do
          j.object do
            j.field "id", user.id.not_nil!
            j.field "name", user.name.to_s
          end
        end
      end
    end
    broadcast_to(r, payload)
  end
end
