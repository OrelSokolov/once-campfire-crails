# ChatLayout — общий каркас страниц Campfire (порт layout_start/layout_end/
# composer/message_uncached из templates/eta express-реализации; JS/CSS —
# пребилд референса в public/assets, фрагменты — app/views/*.html).
module ChatLayout
  STYLESHEETS = {{ read_file "#{__DIR__}/../views/stylesheets.html" }}
  IMPORTMAP   = {{ read_file "#{__DIR__}/../views/importmap.html" }}

  # asset("arrow-up.svg") → "/assets/arrow-up-f96b3895.svg" (manifest
  # пребилда референса).
  def self.asset(name : String) : String
    if entry = manifest[name]?
      "/assets/#{entry}"
    else
      "/assets/#{name}"
    end
  end

  @@manifest : Hash(String, String)?

  private def self.manifest : Hash(String, String)
    @@manifest ||= begin
      raw = JSON.parse({{ read_file "#{__DIR__}/../views/manifest.json" }})
      table = {} of String => String
      raw.as_h.each do |k, v|
        table[k] = v["digested_path"].as_s
      end
      table
    end
  end

  def self.head(title : String, user : User?, room_id : Int64?, chat : Bool) : String
    String.build do |io|
      io << "<!DOCTYPE html>\n<html><head>\n<title>" << HTML.escape(title) << "</title>\n"
      io << %(<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">\n)
      io << %(<meta name="color-scheme" content="light dark">\n)
      io << %(<meta name="turbo-prefetch" content="true">\n)
      if u = user
        io << %(<meta name="current-user-id" content="#{u.id}">\n)
        io << %(<meta name="current-user-name" content=") << HTML.escape(u.name.to_s) << %(">\n)
      end
      io << %(<meta name="action-cable-url" content="/cable">\n)
      io << STYLESHEETS << "\n" << IMPORTMAP << "\n"
      # Custom CSS аккаунта (custom_styles.eta layout_start: <style> в head)
      if (account = Account.take.try(&.custom_styles).to_s) != ""
        io << "<style>\n" << account << "\n</style>\n"
      end
      if chat && room_id
        io << %(<meta name="turbo-cache-control" content="no-preview">\n)
        io << %(<meta name="current-room-id" content="#{room_id}">\n)
      end
      io << "</head>\n"
    end
  end

  # <body> + nav#nav с заголовком комнаты и ссылкой настроек (роль
  # "Settings for this room" — по ней smoke открывает настройки).
  # Direct-комнаты (name NULL): layout_start.eta — for-screen-reader
  # "Ping with " + полные имена остальных участников (roomData Name).
  def self.body_open(room : Room? = nil, viewer : User? = nil) : String
    String.build do |io|
      io << %(<body class="chat" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n)
      if r = room
        if r.name.nil?
          members = User.where(
            %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), r.id.not_nil!)
            .order("id").to_a
            .reject { |m| viewer && m.id == viewer.id }
          names = members.map(&.name.to_s).join(", ")
          io << %(<h1 class="room-name">)
          io << %(<span class="for-screen-reader">Ping with </span>)
          io << HTML.escape(names) << "</h1>\n"
        else
          io << %(<h1 class="room-name">) << HTML.escape(r.name.to_s) << "</h1>\n"
          io << %(<a class="btn" data-room-id="#{r.id}" href="/rooms/#{r.id}/edit">)
          io << %(<span class="for-screen-reader">Settings for this room</span></a>\n)
        end
      end
      io << "</nav>\n"
      io << %(<main id="main-content">\n)
    end
  end

  # footer + sidebar (turbo-frame user_sidebar) + app-logo.
  def self.body_close(chat : Bool) : String
    String.build do |io|
      io << %(<footer id="footer">)
      io << %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade;</div>)
      io << "</footer></main>\n"
      io << %(<aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">)
      if chat
        io << %(<turbo-frame id="user_sidebar" src="/users/me/sidebar" data-turbo-permanent="true" target="_top" )
        io << %(data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" )
        io << %(data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload"></turbo-frame>)
      end
      io << "</aside>\n"
      io << %(<a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">)
      io << %(<img alt="Campfire logo" src="#{asset("campfire-icon.png")}" width="256" height="216"></a>\n)
      io << "</body></html>\n"
    end
  end

  # DOM одного сообщения — message_uncached.eta + presentation.eta
  # (id="message_<cmid>", data-client-message-id: контрактную проверку
  # проходит подстрокой id="<cmid>").
  def self.message_dom(m : Message, room : Room, creator : User?) : String
    cid = m.client_message_id.to_s.presence || m.id.to_s
    mid = m.id.not_nil!
    creator_name = creator.try(&.name).to_s
    created = m.created_at || Time.utc
    updated = m.updated_at || created
    permalink = "/rooms/#{room.id}/@#{mid}"
    avatar_src = "/users/#{m.creator_id}/avatar"

    String.build do |io|
      io << %(<div id="message_#{cid}" class="message" data-controller="reply" )
      io << %(data-user-id="#{m.creator_id}" data-message-id="#{mid}" )
      io << %(data-message-timestamp="#{created.to_unix}" data-message-updated-at="#{updated.to_unix}" )
      io << %(data-sort-value="#{created.to_unix}" data-messages-target="message" )
      io << %(data-search-results-target="message" data-refresh-room-target="message" )
      io << %(data-reply-composer-outlet="#composer" data-client-message-id=") << HTML.escape(cid) << %(">\n)
      io << %(<figure class="avatar message__avatar"><a title=") << HTML.escape(creator_name)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/#{m.creator_id}">)
      io << %(<img aria-hidden="true" src="#{avatar_src}" width="48" height="48" loading="lazy"></a></figure>\n)
      io << %(<turbo-frame id="edit_message_#{cid}"><div class="message__body"><div class="message__body-content">)
      io << %(<div class="message__meta"><h3 class="message__heading">)
      io << %(<span class="message__author" title=") << HTML.escape(creator_name)
      io << %("><strong data-reply-target="author">) << HTML.escape(creator_name) << %(</strong></span>)
      io << %(<a target="_top" class="message__permalink" href="#{permalink}">)
      io << %(<time class="message__timestamp" datetime="#{created.to_rfc3339}"></time></a>)
      io << %(</h3>\n)
      io << message_actions(mid, cid, permalink, room)
      io << %(</div>\n)
      io << %(<div id="presentation_message_#{cid}" dir="auto" data-reply-target="body" data-messages-target="body">)
      io << %(<div class="lexxy-content">) << m.body.to_s << %(</div></div>\n)
      io << %(</div></div></turbo-frame></div>\n)
    end
  end

  # message_actions.eta (ядро): summary-меню с Copy link и Edit.
  private def self.message_actions(mid : Int64, cid : String, permalink : String, room : Room) : String
    String.build do |io|
      io << %(<div class="message__actions"><details class="position-relative" data-controller="popup" )
      io << %(data-popup-orientation-top-class="popup-orientation-top" )
      io << %(data-action="keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside">)
      io << %(<summary class="btn message__action-btn message__options-btn">)
      io << %(<span class="for-screen-reader">Message options</span></summary>)
      io << %(<div class="message__actions-menu border shadow" data-popup-target="menu">)
      io << %(<div class="flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid">)
      io << %(<button class="btn message__action-btn center full-width" title="Copy link" aria-label="Copy link" )
      io << %(data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" )
      io << %(data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-url-value="#{permalink}">)
      io << %(<span class="for-screen-reader">Copy link</span></button>\n)
      io << %(<a class="btn message__action-btn center full-width message__edit-btn" data-turbo-frame="edit_message_#{cid}" )
      io << %(title="Edit" aria-label="Edit" href="/rooms/#{room.id}/messages/#{mid}/edit">)
      io << %(<span class="for-screen-reader">Edit</span></a>)
      io << %(</div></div></details></div>\n)
    end
  end

  # DOM-список сообщений с fragment-кэшем — порт Rails `render partial:,
  # collection:, cached:` (rooms/show.html.erb + FragmentCache
  # референса): хиты берутся из кэша одним проходом до любых SQL;
  # промахи рендерятся свежо — их комнаты (кроме переданной) и авторы
  # догружаются одним IN-запросом на сущность — и пишутся в кэш.
  # Ключ = cache_key_with_version (id + updated_at), свежесть — общий
  # DB-epoch (см. FragmentCache).
  def self.messages_to(io : IO, messages : Array(Message), epoch : String,
                       room : Room? = nil) : Nil
    hits = {} of Int64 => String
    misses = [] of Message
    messages.each do |m|
      if (html = FragmentCache.get(FragmentCache.key(m), epoch))
        hits[m.id.not_nil!] = html
      else
        misses << m
      end
    end

    rooms = {} of Int64 => Room
    if r = room
      rooms[r.id.not_nil!] = r
    else
      room_ids = misses.map(&.room_id.not_nil!).uniq
      unless room_ids.empty?
        Room.where(id: room_ids).each { |r| rooms[r.id.not_nil!] = r }
      end
    end
    creators = {} of Int64 => User
    creator_ids = misses.map(&.creator_id.not_nil!).uniq
    unless creator_ids.empty?
      User.where(id: creator_ids).each { |u| creators[u.id.not_nil!] = u }
    end

    messages.each do |m|
      if (html = hits[m.id.not_nil!]?)
        io << html
      elsif (r = rooms[m.room_id.not_nil!]?)
        html = message_dom(m, r, creators[m.creator_id.not_nil!]?)
        FragmentCache.set(FragmentCache.key(m), epoch, html)
        io << html
      end
    end
  end

  # String-обёртка над messages_to (rooms#show: результат уходит в
  # message_area).
  def self.messages_html(messages : Array(Message), epoch : String,
                         room : Room? = nil) : String
    String.build { |io| messages_to(io, messages, epoch, room) }
  end

  # composer.eta — форма отправки сообщения (lexxy-editor). Портировано
  # целиком: targets/атрибуты нужны composer/typing-notifications
  # контроллерам (нехватка валит click->composer#submit).
  def self.composer(room : Room) : String
    String.build do |io|
      io << %(<div class="composer flex align-end gap position-relative" data-controller="typing-notifications" )
      io << %(data-typing-notifications-active-class="typing-indicator--active">\n)
      io << %(<a class="btn flex-item-no-shrink margin-block-end composer__context-btn" href="/searches">)
      io << %(<span class="for-screen-reader">Search</span></a>\n)
      io << %(<turbo-frame id="composer-frame">\n)
      io << %(<form id="composer" class="margin-block flex-item-grow contain" data-controller="composer drop-target" )
      io << %(data-action="dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop )
      io << %(typing-notifications#stop paste-&gt;composer#pasteFiles turbo:submit-end-&gt;composer#submitEnd" )
      io << %(data-composer-messages-outlet="#message-area" data-composer-toolbar-class="composer--rich-text" )
      io << %(data-composer-room-id-value="#{room.id}" )
      io << %(action="/rooms/#{room.id}/messages" accept-charset="UTF-8" method="post">\n)
      io << %(<fieldset data-composer-target="fields" contents>\n<div class="flex flex-column">\n)
      io << %(<div class="composer__filelist flex flex--align-center gap flex-wrap" data-composer-target="fileList"></div>\n)
      io << %(<div class="flex composer__input input input--actor fill-white min-width" style="--input-border-radius: 1.3rem">\n)
      io << %(<div class="flex align-end gap full-width">\n)
      io << %(<lexxy-editor rows="1" class="input lexxy-content" style="order: -1" aria-multiline="true" aria-label="Write a message" )
      io << %(permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" )
      io << %(data-action="lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft" )
      io << %(data-composer-target="text" id="message_body" name="message[body]">)
      io << %(<lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id=#{room.id}" remote-filtering="true" empty-results="No matches"></lexxy-prompt>)
      io << %(</lexxy-editor>\n)
      io << %(<button name="send" type="submit" data-action="composer#submit" class="btn btn--reversed flex-item-no-shrink txt-small">)
      io << %(<span class="for-screen-reader">Send Message</span></button>\n)
      io << %(</div>\n</div>\n</div>\n</fieldset>\n)
      io << %(<div class="typing-indicator gap txt-small align-center flex-inline" data-typing-notifications-target="indicator">)
      io << %(<div class="typing-indicator__author spinner" data-typing-notifications-target="author"></div></div>\n)
      io << %(<input data-composer-target="clientid" type="hidden" name="message[client_message_id]" id="message_client_message_id">\n)
      io << %(</form>\n</turbo-frame>\n</div>\n)
    end
  end

  # message-area целиком (optimistic-шаблон + .messages + стрим-источник
  # + composer) — room.eta + optimistic.eta. Optimistic-template нужен
  # messages-контроллеру как target "template".
  def self.message_area(room : Room, messages_html : String, user : User) : String
    signed_name = HTML.escape(Turbo::Streams::StreamName.signed_stream_name([room, "messages"]))
    String.build do |io|
      io << %(<div id="message-area" class="message-area" contents="true" data-controller="messages presence drop-target" )
      io << %(data-action="turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage visibilitychange@document-&gt;presence#visibilityChanged" )
      io << %(data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" )
      io << %(data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" )
      io << %(data-messages-threaded-class="message--threaded" data-messages-page-url-value="/rooms/#{room.id}/messages">\n)
      io << %(<script type="text/template" data-messages-target="template">\n)
      io << %(<div class="message message--me $messageClasses$" id="message_$clientMessageId$" )
      io << %(data-format-message-target="message" data-user-id="#{user.id}" )
      io << %(data-message-timestamp="$messageTimestamp$" data-messages-target="message">\n)
      io << %(<figure class="avatar message__avatar"><a title=") << HTML.escape(user.name.to_s)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/#{user.id}">)
      io << %(<img aria-hidden="true" src="/users/#{user.id}/avatar" width="48" height="48"></a></figure>\n)
      io << %(<div class="message__body"><div class="message__body-content"><div class="message__meta">)
      io << %(<h3 class="message__heading"><span class="message__author"><strong>)
      io << HTML.escape(user.name.to_s) << %(</strong></span></h3></div>\n)
      io << %($body$\n</div></div></div>\n)
      io << %(</script>\n)
      io << %(<div id="messages_room_#{room.id}" class="messages" data-controller="maintain-scroll refresh-room" )
      io << %(data-action="turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online" )
      io << %(data-messages-target="messages" data-refresh-room-url-value="/rooms/#{room.id}/refresh">\n)
      io << messages_html
      io << %(</div>\n)
      io << %(<turbo-cable-stream-source channel="RoomMessagesChannel" signed-stream-name="#{signed_name}"></turbo-cable-stream-source>\n)
      io << %(<button class="message-area__return-to-latest btn" data-action="messages#returnToLatest" data-messages-target="latest" hidden="hidden">)
      io << %(<span class="for-screen-reader">Jump to newest message</span></button>\n)
      io << %(</div>\n)
    end
  end
end
