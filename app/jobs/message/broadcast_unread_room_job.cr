require "../application_job"

class Message::BroadcastUnreadRoomJob < ApplicationJob
  def self.perform(data : JSON::Any) : Nil
    message_id = data["message_id"]?.try(&.to_s.to_i64?)
    return unless message_id

    conn = ActiveRecord::Base.connection
    message = conn.query_one?(
      "SELECT room_id, created_at FROM messages WHERE id = ?", message_id) do |rs|
      {room_id: rs.read(Int64), created_at: rs.read(Time)}
    end
    return unless message

    user_ids = conn.query_all(
      "SELECT user_id FROM memberships WHERE room_id = ? " \
      "AND (unread_at IS NOT NULL OR connected_at >= ?)",
      message[:room_id], Time.utc - 60.seconds) do |rs|
      rs.read(Int64)
    end

    user_ids.each do |uid|
      ActionCable.server.broadcast(UnreadRoomsChannel.stream_name_for(uid.to_s),
        {"roomId" => message[:room_id], "at" => message[:created_at].to_unix_f})
    end
  end
end
