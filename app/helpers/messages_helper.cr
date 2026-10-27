# ERB helpers for app/views/messages/{show,edit}.html.erb, included in MessagesController.
module MessagesHelper
  include ActionController::Helper

  # show.html.erb: the message DOM (same message_dom as in the room).
  def message_dom : ERB::SafeString
    message = self.message.not_nil!
    attachment = ChatLayout.attachments_for([message.id!])[message.id!]?
    ERB::SafeString.new(ChatLayout.message_dom(message, room.not_nil!,
      User.find?(message.creator_id!), attachment, base_url: origin))
  end

  # edit.html.erb: attachment presentation (attachment branch).
  def attachment_html : ERB::SafeString
    ERB::SafeString.new(ChatLayout.attachment_presentation(attachment.not_nil!))
  end

  # Oracle messages/index.html.erb: `render partial: "messages/message",
  # collection: @messages, cached: ->(message) { ... }` — the collection
  # render of the message partial. Each entry renders the same DOM as in
  # the room (message_dom); the list is served through the fragment cache
  # (no SQL on hits; miss rooms/authors loaded with one IN query per
  # entity — ChatLayout.messages_to). The oracle's cached-lambda computes
  # a content key; the port's FragmentCache is epoch-keyed (known-gaps),
  # so `cached:` only carries the call shape.
  def render(partial : String, *, collection : Array(Message),
             cached : Bool = true) : ERB::SafeString
    raise ArgumentError.new("Missing partial #{partial.inspect}") unless partial == "messages/message"
    ERB::SafeString.new(
      ChatLayout.messages_html(collection, db_epoch, @room, origin))
  end
end
