require "../application_job"

class Message::BroadcastUnreadRoomJob < ApplicationJob
  serialized message: Message

  def self.queue_kind : String
    "broadcast_unread_room"
  end

  def perform(message : Message) : Nil
    room = message.room.not_nil!
    created_at = message.created_at || Time.utc

    user_ids = room.memberships.unread.or(room.memberships.connected)
      .pluck(:user_id).map(&.as(Int64))

    user_ids.each do |uid|
      ActionCable.server.broadcast(UnreadRoomsChannel.stream_name_for(uid.to_s),
        {"roomId" => room.id!, "at" => created_at.to_f})
    end
  end
end
