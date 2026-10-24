require "../application_job"

class Room::DestroyJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  serialized room: Room, former_member_ids: Array(Int64)

  def self.queue_kind : String
    "room_destroy"
  end

  # The room may already be gone by the time the job runs — the discarded
  # DeserializationError covers it.
  def perform(room : Room, former_member_ids : Array(Int64)) : Nil
    room_id = room.id.not_nil!
    former_member_ids.each do |uid|
      if (user = User.find?(uid))
        user.reset_remote_connections
      end
    end

    conn = ActiveRecord::Base.connection
    conn.query_all(
      "SELECT id FROM messages WHERE room_id = ? ORDER BY id", room_id) do |rs|
      rs.read(Int64)
    end.each do |mid|
      conn.exec("DELETE FROM boosts WHERE message_id = ?", mid)
      conn.exec(
        "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
      Message::Searchable.remove_from_index(conn, mid)
      conn.exec("DELETE FROM messages WHERE id = ?", mid)
      Message::Broadcasts.broadcast_remove(room_id, mid)
    end
    conn.exec("DELETE FROM rooms WHERE id = ?", room_id)
    Campfire::ResponseCache.invalidate!
  end
end
