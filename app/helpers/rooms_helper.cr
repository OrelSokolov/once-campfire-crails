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
        ChatLayout.chat_sidebar_frame)
    end
    Campfire::ResponseCache::Page.new(html)
  end

  def invitation_html(room : Room, user : User) : String
    original = Room.order("created_at").first?
    return "" unless original && original.id == room.id
    return "" if Message.where("room_id = ?", room.id.not_nil!)
      .offset(40).exists?
    ChatLayout.system_welcome(origin)
  end

  # An empty update set still renders a lone "\n" text node after </body>,
  # matching the reference Turbo output.
  def refresh_stream(room : Room, new_messages : Array(Message),
                     updated_messages : Array(Message)) : String
    epoch = db_epoch
    String.build do |io|
      unless new_messages.empty?
        io << %(<turbo-stream action="append" target="messages_#{room.dom_id}"><template>)
        io << ChatLayout.messages_html(new_messages, epoch, room, origin)
        io << %(</template></turbo-stream>)
      end
      io << '\n'
      updated_messages.each do |message|
        io << %(<turbo-stream action="replace" target="message_#{message.id}"><template>)
        io << ChatLayout.messages_html([message], epoch, room, origin)
        io << %(</template></turbo-stream>\n)
      end
    end
  end

  # rooms/directs/edit.html.erb shell (the directs edit screen keeps its own
  # wrapper; the opens/closeds pages moved to rooms/layouts/*).
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("room-form", title,
      nav_html: ChatLayout.nav_back(back_path)))
  end

  # Oracle layouts (rooms/layouts/_new|_edit.html.erb): back to the last
  # visited room — edit pages to the room itself, new pages to the root
  # (byte-identical to the previous inline page_open back link).
  def link_back_to_last_room_visited : ERB::SafeString
    path = if (r = @room) && (rid = r.id)
             "/rooms/#{rid}"
           else
             "/"
           end
    ERB::SafeString.new(
      %(<a class="btn" href="#{path}">) +
      icon("arrow-left.svg").raw +
      %(<span class="for-screen-reader">Go Back</span></a>))
  end

  # The delete-room form of the edit layout (rooms/layouts/_edit.html.erb).
  def button_to_delete_room(room : Room) : ERB::SafeString
    ERB::SafeString.new(
      %(<form action="#{origin}/rooms/#{room.id.not_nil!}" class="button_to" method="post"><input name="_method" type="hidden" value="delete"><button aria-label="Delete #{room.name.to_s}" class="btn btn--negative max-width" data-turbo-confirm="Are you sure you want to delete this room and all messages in it? This can’t be undone." type="submit">) +
      icon("trash.svg").raw +
      %(<span class="overflow-ellipsis">#{room.name.to_s}</span></button></form>))
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
