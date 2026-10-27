module RoomsHelper
  include ActionController::Helper
  def room_page(room : Room, user : User, messages : Array(Message)) : Campfire::ResponseCache::Page
    messages_html = invitation_html(room, user) +
                    ChatLayout.messages_html(messages, db_epoch, room, origin)

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    # rooms/show.html.erb: @page_title/@body_class + content_for
    # :head/:nav/:footer/:sidebar; the page shell is layouts/application.
    @page_title = if (n = room.name)
                    n.to_s
                  else
                    others = User.where(
                      %(id IN (SELECT user_id FROM memberships WHERE room_id = ? AND user_id != ?)),
                      room.id!, user.id!).order("id").map(&.name.to_s)
                    ChatLayout.display_sentence(others, user.name.to_s)
                  end
    @body_class = "sidebar"
    content_for(:head) do
      ERB::SafeString.new(%(<meta name="turbo-cache-control" content="no-preview">\n) +
        %(<meta name="current-room-id" content="#{room.id}">\n))
    end
    content_for(:nav) do
      ERB::SafeString.new(ChatLayout.chat_nav(room,
        ua: request.headers["User-Agent"]?.to_s, origin: origin))
    end
    # rooms/show/_composer renders into content_for :footer (oracle
    # show.html.erb); the layout reads it back in yield :footer.
    chat_erb = ChatERB.new(room: room, origin: origin)
    chat_erb.composer
    content_for(:footer) { chat_erb.content_for(:footer) }
    content_for(:sidebar) { sidebar_turbo_frame_tag(src: user_sidebar_path) }
    html = __render_layout {
      ChatLayout.message_area(room, messages_html, base_url: origin)
    }.to_s
    Campfire::ResponseCache::Page.new(html)
  end

  def invitation_html(room : Room, user : User) : String
    original = Room.order("created_at").first?
    return "" unless original && original.id == room.id
    return "" if Message.where("room_id = ?", room.id!)
      .offset(40).exists?
    account = Account.take
    join_url = origin + "/join/" + account.try(&.join_code).to_s
    invite = render(partial: "accounts/invite", locals: {"url" => join_url}).raw
    ChatLayout.system_welcome(origin, invite)
  end

  # Oracle rooms/refreshes/show.turbo_stream.erb: the append/replace
  # content is `render partial: "messages/message", collection:`,
  # cached:` (the messages/message partial through the fragment-cache hot
  # path). `cached:` carries the oracle call shape; the port's cache is
  # epoch-keyed (known-gaps).
  def render(partial : String, *, collection : Array(Message),
             cached : Bool = true) : ERB::SafeString
    raise ArgumentError.new("Missing partial #{partial.inspect}") unless partial == "messages/message"
    ERB::SafeString.new(
      ChatLayout.messages_html(collection, db_epoch, @room, origin))
  end

  # Oracle rooms_helper.rb link_back_to_last_room_visited: back to the last
  # visited room. The crails port keeps the @room-based selection (edit
  # pages to the room itself, new pages to the root); the oracle reads the
  # last_room cookie through the last_room_visited helper_method.
  def link_back_to_last_room_visited : ERB::SafeString
    path = if (r = @room) && (rid = r.id)
             room_path(rid)
           else
             root_path
           end
    link_back_to path
  end

  # The delete-room form of the edit layout (rooms/layouts/_edit.html.erb).
  def button_to_delete_room(room : Room) : ERB::SafeString
    button_to "#{origin}/rooms/#{room.id!}", method: "delete",
      class: "btn btn--negative max-width", aria: {label: "Delete #{room.name.to_s}"},
      data: {turbo_confirm: "Are you sure you want to delete this room and all messages in it? This can’t be undone."} do
      icon("trash.svg") + tag.span(room.name.to_s, class: "overflow-ellipsis")
    end
  end

  def avatar_link(member : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(member, "lazy"))
  end

  def everyone_src : String
    ChatLayout.asset("everyone.svg")
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def checked_attr(checked : Bool) : ERB::SafeString
    ERB::SafeString.new(checked ? %( checked="checked") : "")
  end
end
