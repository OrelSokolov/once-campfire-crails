require "../application_record"

class Message
  module Broadcasts
    # The cable frame carries no trailing \n (that only appears in the controller-built
    # create.turbo_stream.erb HTTP response). Rails renders the partial with Erubi, which
    # swallows newlines after <% end %> so the oracle's partial ends exactly at </div>;
    # chomp ours, or Turbo appends a whitespace text node after the message.
    def self.broadcast_create(room : Room, message : Message, author : User,
                              attachment : ChatLayout::Attachment? = nil,
                              base_url : String = "") : Nil
      Turbo::StreamsChannel.broadcast_append_to([room, "messages"],
        target: "messages_#{room.dom_id}",
        html: ChatLayout.message_dom(message, room, author, attachment, base_url: base_url).chomp)
    end

    # The room may already be destroyed — then the stream is gone and there is nothing to remove.
    def self.broadcast_remove(room_id : Int64, message_id : Int64) : Nil
      if (room = Room.find?(room_id))
        Turbo::StreamsChannel.broadcast_remove_to([room, "messages"],
          target: "message_#{message_id}")
      end
    end

    # Message::BroadcastUnreadRoomJob enqueue tuple — the JobQueue DB write must stay
    # outside the production transaction (see MessageCreator#create!).
    def self.broadcast_unread_room_later(message : Message) : Tuple(String, String)
      Message::BroadcastUnreadRoomJob.__queue_pair(message)
    end

    # Fanned out to the room's members rather than published on one global stream, so
    # that the timing of activity in a room only reaches people who are in it. Of those,
    # only the ones who still have it unread or are in it now: by the time this runs,
    # someone may have opened the room and moved on, and would see it marked unread again.
    def broadcast_unread_room : Nil
      room = self.room.not_nil!
      at = created_at || Time.utc

      room.memberships.unread.or(room.memberships.connected)
        .pluck(:user_id).map(&.as(Int64)).each do |user_id|
        ActionCable.server.broadcast(UnreadRoomsChannel.stream_name_for(user_id.to_s),
          {"roomId" => room.id!, "at" => at.to_f})
      end
    end

    # The room may already be destroyed — then the stream is gone and there is nothing to remove.
    def broadcast_remove : Nil
      Message::Broadcasts.broadcast_remove(room_id!, id!)
    end
  end
  include Broadcasts
end
