require "../application_job"

class Message::BroadcastUnreadRoomJob < ApplicationJob
  serialized message: Message

  def self.queue_kind : String
    "broadcast_unread_room"
  end

  def perform(message : Message) : Nil
    room_id = message.room_id.not_nil!
    created_at = message.created_at || Time.utc

    conn = ActiveRecord::Base.connection
    user_ids = conn.query_all(
      "SELECT user_id FROM memberships WHERE room_id = ? " \
      "AND (unread_at IS NOT NULL OR connected_at >= ?)",
      room_id, Time.utc - 60.seconds) do |rs|
      rs.read(Int64)
    end

    user_ids.each do |uid|
      ActionCable.server.broadcast(UnreadRoomsChannel.stream_name_for(uid.to_s),
        {"roomId" => room_id, "at" => created_at.to_unix_f})
    end
  end
end
