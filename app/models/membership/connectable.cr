require "../application_record"

class Membership
  module Connectable
    CONNECTION_TTL = 60.seconds

    def self.connect(room_id : Int64, user_id : String) : Nil
      conn = ActiveRecord::Base.connection
      now = Time.utc
      conn.exec(
        "UPDATE memberships SET connected_at = ?, unread_at = NULL, " \
        "connections = CASE WHEN connected_at >= ? THEN connections + 1 ELSE 1 END " \
        "WHERE room_id = ? AND user_id = ?",
        now, now - CONNECTION_TTL, room_id, user_id)
    end

    def self.disconnect(room_id : Int64, user_id : String) : Nil
      ActiveRecord::Base.connection.exec(
        "UPDATE memberships SET connections = MAX(connections - 1, 0) WHERE room_id = ? AND user_id = ?",
        room_id, user_id)
    end

    def self.refresh_connection(room_id : Int64, user_id : String) : Nil
      ActiveRecord::Base.connection.exec(
        "UPDATE memberships SET connected_at = ? WHERE room_id = ? AND user_id = ?",
        Time.utc, room_id, user_id)
    end
  end
end
