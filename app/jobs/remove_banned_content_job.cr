require "./application_job"

class RemoveBannedContentJob < ApplicationJob
  serialized user: User

  def self.queue_kind : String
    "remove_banned_content"
  end

  def perform(user : User) : Nil
    # remove_banned_content of the reference: each message is destroyed
    # (boosts / rich_text / search index ride on destroy callbacks) and
    # its removal is broadcast to the room's stream.
    user.messages.order("id").each do |message|
      room_id = message.room_id.not_nil!
      message.destroy
      Message::Broadcasts.broadcast_remove(room_id, message.id.not_nil!)
    end
  end
end
