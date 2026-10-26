module RoomsHelper
  include ActionController::Helper
  def room_page(room : Room, user : User, messages : Array(Message)) : Campfire::ResponseCache::Page
    messages_html = invitation_html(room, user) +
                    ChatLayout.messages_html(messages, db_epoch, room, origin)

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    title = if (n = room.name)
              n.to_s
            else
              others = User.where(
                %(id IN (SELECT user_id FROM memberships WHERE room_id = ? AND user_id != ?)),
                room.id.not_nil!, user.id.not_nil!).order("id").map(&.name.to_s)
              ChatLayout.display_sentence(others, user.name.to_s)
            end
    html = String.build do |io|
      io << ChatLayout.head(title, room.id, chat: true)
      io << ChatLayout.body_open(room,
        ua: request.headers["User-Agent"]?.to_s, origin: origin)
      io << ChatLayout.message_area(room, messages_html, base_url: origin)
      io << ChatLayout.page_close(ChatERB.new(room: room, origin: origin).composer.to_s,
        sidebar_turbo_frame_tag(src: user_sidebar_path).raw)
    end
    Campfire::ResponseCache::Page.new(html)
  end

  def invitation_html(room : Room, user : User) : String
    original = Room.order("created_at").first?
    return "" unless original && original.id == room.id
    return "" if Message.where("room_id = ?", room.id.not_nil!)
      .offset(40).exists?
    account = Account.take
    join_url = origin + "/join/" + account.try(&.join_code).to_s
    invite = render(partial: "accounts/invite", locals: {"url" => join_url}).raw
    ChatLayout.system_welcome(origin, invite)
  end

  # rooms/refreshes/show.turbo_stream.erb: the message list markup for
  # turbo_stream append/replace content (the oracle renders the
  # messages/message partial collection; the port compiles it at build time).
  def messages_html(room : Room, messages : Array(Message)) : String
    ChatLayout.messages_html(messages, db_epoch, room, origin)
  end

  # rooms/directs/edit.html.erb shell (the directs edit screen keeps its own
  # wrapper; the opens/closeds pages moved to rooms/layouts/*).
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("room-form", title,
      nav_html: nav_back_to(back_path).raw))
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
    button_to "#{origin}/rooms/#{room.id.not_nil!}", method: "delete",
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
