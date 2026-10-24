require "./application_job"

class RemoveBannedContentJob < ApplicationJob
  serialized user: User

  def self.queue_kind : String
    "remove_banned_content"
  end

  def perform(user : User) : Nil
    user_id = user.id.not_nil!
    conn = ActiveRecord::Base.connection
    messages = conn.query_all(
      "SELECT id, room_id FROM messages WHERE creator_id = ? ORDER BY id", user_id) do |rs|
      {id: rs.read(Int64), room_id: rs.read(Int64)}
    end

    messages.each do |message|
      mid = message[:id]
      conn.exec("DELETE FROM boosts WHERE message_id = ?", mid)
      conn.exec(
        "DELETE FROM action_text_rich_texts WHERE record_type='Message' AND record_id=?", mid)
      Message::Searchable.remove_from_index(conn, mid)
      conn.exec("DELETE FROM messages WHERE id = ?", mid)
      Message::Broadcasts.broadcast_remove(message[:room_id], mid)
    end
    Campfire::ResponseCache.invalidate!
  end
end
