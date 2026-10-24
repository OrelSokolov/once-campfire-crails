require "../application_record"

class Message
  module Pagination
    PAGE_SIZE = 40

    def self.page_before(room : Room, anchor_id : Int64) : Array(Message)
      Message.where(
        "room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, anchor_id)
        .order("created_at DESC").limit(PAGE_SIZE).to_a.reverse
    end

    def self.page_after(room : Room, anchor_id : Int64) : Array(Message)
      Message.where(
        "room_id = ? AND created_at > (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, anchor_id)
        .order("created_at ASC").limit(PAGE_SIZE).to_a
    end

    def self.last_page(room : Room) : Array(Message)
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(PAGE_SIZE).to_a.reverse
    end

    def self.page_created_since(room : Room, since : Time) : Array(Message)
      Message.where(
        "room_id = ? AND created_at > ?", room.id.not_nil!, since)
        .order("created_at ASC").limit(PAGE_SIZE).to_a
    end

    # Sorting on +created_at, which no index covers, has SQLite find the few messages updated since
    # through (room_id, updated_at) and sort just those, instead of walking the whole room by
    # (room_id, created_at) looking for them.
    def self.page_updated_since(room : Room, since : Time) : Array(Message)
      Message.where(
        "room_id = ? AND updated_at > ?", room.id.not_nil!, since)
        .order("created_at DESC").limit(PAGE_SIZE).to_a.reverse
    end
  end
end
