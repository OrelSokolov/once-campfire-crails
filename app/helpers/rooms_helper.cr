# RoomsHelper — ERB-хелперы app/views/rooms/{new,edit,_form}.html.erb и
# rooms/show/{_messages,_invitation}.html.erb + show.turbo_stream.erb:
# каркас страницы формы комнаты, страница комнаты целиком (whole-page
# cache строится из них), turbo-stream опрос refresh, карточка участника
# direct-комнаты, аватар «Everyone». Включается в RoomsController; общий
# icon/page_close — ApplicationHelper (ApplicationController).
module RoomsHelper
  # rooms/show.html.erb целиком: message-area + композер (content_for
  # :footer) + layout-каркас. Данные (messages) готовит контроллер
  # (find_messages), здесь только разметка.
  def room_page(room : Room, user : User, messages : Array(Message)) : Campfire::ResponseCache::Page
    messages_html = invitation_html(room, user) +
                    ChatLayout.messages_html(messages, db_epoch, room, origin)

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    # rooms/show.html.erb: @page_title = room_display_name(@room) —
    # direct-комнаты без имени: имена собеседников (to_sentence).
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
      # Композер — content_for :footer референса (rooms/show/_composer).
      io << ChatLayout.page_close(ChatERB.new(room: room, origin: origin).composer.to_s,
        ChatLayout.chat_sidebar_frame)
    end
    Campfire::ResponseCache::Page.new(html)
  end

  # rooms/show/_invitation.html.erb: блок «Welcome to Campfire» — только
  # в исходной комнате (Room.original = первая по created_at) и пока она
  # не пагинируется (Message::Pagination: paged? = offset(40).exists?).
  def invitation_html(room : Room, user : User) : String
    original = Room.order("created_at").first?
    return "" unless original && original.id == room.id
    return "" if Message.where("room_id = ?", room.id.not_nil!)
      .offset(40).exists?
    ChatLayout.system_welcome(origin)
  end

  # rooms/refreshes/show.turbo_stream.erb: новые сообщения — append в
  # контейнер, обновлённые — replace по dom_id. Пустой набор рендерится
  # как одиночный "\n" — Turbo рендерит его в DOM, оставляя text-узел
  # ребёнком <html> после </body> (видно в артефактах).
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

  # head + body + nav (назад на back_path) + main (screen "room-form").
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("room-form", title,
      nav_html: ChatLayout.nav_back(back_path)))
  end

  # Карточка участника direct-комнаты (avatar_link c lazy-загрузкой).
  def avatar_link(member : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(member, "lazy"))
  end

  def everyone_src : String
    ChatLayout.asset("everyone.svg")
  end

  # translation_button (translations_helper) — SafeString для <%= %>.
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  # Rails boolean-атрибут checked="checked" — SafeString, чтобы <%= %>
  # не экранировал кавычки повторно.
  def checked_attr(checked : Bool) : ERB::SafeString
    ERB::SafeString.new(checked ? %( checked="checked") : "")
  end
end
