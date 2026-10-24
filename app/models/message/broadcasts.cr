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
  end
end
