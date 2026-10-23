require "../application_record"

# Message::Pagination (message/pagination.rb): страница истории —
# PAGE_SIZE сообщений; before → 40 строго до anchor (вывод ASC),
# after → 40 строго после, без anchor — последние 40 ASC.
# Rails Page < Array — в Crystal дженерики не наследуются, поэтому
# методы возвращают Array(Message) (отклонение зафиксировано в notes).
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

    # refreshes#show: created_at > since — первая страница (ASC).
    def self.page_created_since(room : Room, since : Time) : Array(Message)
      Message.where(
        "room_id = ? AND created_at > ?", room.id.not_nil!, since)
        .order("created_at ASC").limit(PAGE_SIZE).to_a
    end

    # refreshes#show: updated_at > since — последняя страница сортировки
    # по created_at (DESC limit PAGE_SIZE → ASC).
    def self.page_updated_since(room : Room, since : Time) : Array(Message)
      Message.where(
        "room_id = ? AND updated_at > ?", room.id.not_nil!, since)
        .order("created_at DESC").limit(PAGE_SIZE).to_a.reverse
    end
  end
end
