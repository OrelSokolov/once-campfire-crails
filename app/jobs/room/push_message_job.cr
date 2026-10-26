require "../application_job"

class Room::PushMessageJob < ApplicationJob
  serialized room: Room, message: Message

  def self.queue_kind : String
    "push"
  end

  def perform(room : Room, message : Message) : Nil
    Room::MessagePusher.push(message.id!)
  end
end
