require "./application_job"

# RemoveBannedContentJob (remove_banned_content_job.rb референса):
# User#remove_banned_content — destroy всех сообщений юзера с
# broadcast_remove каждого. Шаги удаления — как messages#destroy
# порта (ActionText-тело + FTS5-индекс + строка), boosts —
# dependent: :destroy референса (express deleteMessage).
class RemoveBannedContentJob < ApplicationJob
  def self.perform(data : JSON::Any) : Nil
    user_id = data["user_id"]?.try(&.to_s.to_i64?)
    return unless user_id

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
    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша
  end
end
