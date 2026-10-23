require "../application_job"

# Room::PushMessageJob (room/push_message_job.rb референса):
# Room::MessagePusher#push — доставка Web Push получателям сообщения.
class Room::PushMessageJob < ApplicationJob
  def self.perform(data : JSON::Any) : Nil
    message_id = data["message_id"]?.try(&.to_s.to_i64?)
    return unless message_id
    Room::MessagePusher.push(message_id)
  end
end
