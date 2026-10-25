# ERB helpers for app/views/messages/{show,edit}.html.erb, included in MessagesController.
module MessagesHelper
  include ActionController::Helper

  # show.html.erb: the message DOM (same message_dom as in the room).
  def message_dom : ERB::SafeString
    message = self.message.not_nil!
    attachment = ChatLayout.attachments_for([message.id.not_nil!])[message.id.not_nil!]?
    ERB::SafeString.new(ChatLayout.message_dom(message, room.not_nil!,
      User.find?(message.creator_id.not_nil!), attachment, base_url: origin))
  end

  # edit.html.erb: attachment presentation (attachment branch).
  def attachment_html : ERB::SafeString
    ERB::SafeString.new(ChatLayout.attachment_presentation(attachment.not_nil!))
  end

  # Each entry renders the same DOM as in the room (message_dom): a minimal
  # <article> fails route-contract-v1 loadgen. The list is served through the
  # fragment cache (no SQL on hits; miss authors loaded with a single IN query).
  # Rails messages/index.html.erb (layout false) is a bare collection of message
  # partials inserted as a fragment into .messages by the JS paginator.
  def messages_page_html(room : Room, messages : Array(Message),
                         epoch : String) : String
    String.build do |io|
      ChatLayout.messages_to(io, messages, epoch, room, origin)
    end
  end
end
