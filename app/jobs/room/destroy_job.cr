require "../application_job"

# Room::DestroyJob (room/destroy_job.rb референса): комнаты больше нет
# у участников сразу (членства сняты в destroy_later); сообщения
# удаляются по одному в собственной транзакции — прочие записи проходят
# между удалениями. Комната исчезла к моменту джобы — no-op (аналог
# discard_on ActiveJob::DeserializationError).
class Room::DestroyJob < ApplicationJob
  def self.perform(data : JSON::Any) : Nil
    room_id = data["room_id"]?.try(&.to_s.to_i64?)
    return unless room_id
    former_member_ids = data["former_member_ids"]?.try do |ids|
      ids.as_a.map(&.to_s.to_i64)
    end || [] of Int64

    return unless Room.find?(room_id)

    # Сброс live-подключений бывших участников: их cable-подписки на
    # стримы комнаты перестают получать сообщения до реконнекта.
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
    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша
  end
end
