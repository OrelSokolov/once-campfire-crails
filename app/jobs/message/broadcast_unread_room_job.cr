require "../application_job"

class Message::BroadcastUnreadRoomJob < ApplicationJob
  serialized message: Message

  def self.queue_kind : String
    "broadcast_unread_room"
  end

  def perform(message : Message) : Nil
    message.broadcast_unread_room
  end
end
