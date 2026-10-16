# ChatLayout — общий каркас страниц Campfire (порт layout_start/layout_end/
# composer/message_uncached из templates/eta express-реализации; JS/CSS —
# пребилд референса в public/assets, фрагменты — app/views/*.html).
module ChatLayout
  STYLESHEETS = {{ read_file "#{__DIR__}/../views/stylesheets.html" }}
  IMPORTMAP   = {{ read_file "#{__DIR__}/../views/importmap.html" }}

  # file_uploader.js читает meta[name=csrf-token] перед fetch; сервер
  # CSRF не проверяет, поэтому достаточно стабильного значения на процесс.
  CSRF_TOKEN = Random::Secure.hex(32)

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

  # direct :fresh_account_logo (config/routes.rb референса): account_logo
  # c cache-busting v=account.updated_at (to_fs(:number)) — смена логотипа
  # или настроек меняет URL и обходит кэш иконки. size=small — 192px.
  def self.fresh_account_logo_path(account : Account?, size : String? = nil) : String
    return "/account/logo" unless account
    query = [] of String
    if (stamp = account.updated_at.try(&.to_s("%Y%m%d%H%M%S")))
      query << "v=#{stamp}"
    end
    query << "size=#{size}" if size
    query.empty? ? "/account/logo" : "/account/logo?#{query.join("&")}"
  end

  def self.head(title : String, user : User?, room_id : Int64?, chat : Bool,
                head_extra : String = "") : String
    String.build do |io|
      io << "<!DOCTYPE html>\n<html><head>\n<title>" << HTML.escape(title) << "</title>\n"
      io << %(<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">\n)
      io << %(<meta name="color-scheme" content="light dark">\n)
      io << %(<meta name="turbo-prefetch" content="true">\n)
      io << %(<meta name="csrf-token" content="#{CSRF_TOKEN}">\n)
      if u = user
        io << %(<meta name="current-user-id" content="#{u.id}">\n)
        io << %(<meta name="current-user-name" content=") << HTML.escape(u.name.to_s) << %(">\n)
      end
      io << %(<meta name="action-cable-url" content="/cable">\n)
      # layouts/application.html.erb: tag.link rel: "manifest"/"icon"/
      # "apple-touch-icon" → fresh_account_logo (логотип аккаунта как
      # favicon, с cache-busting по updated_at).
      account = Account.take
      if account
        logo = fresh_account_logo_path(account)
        io << %(<link rel="manifest" href="/webmanifest.json">\n)
        io << %(<link rel="icon" href="#{logo}" type="image/png">\n)
        io << %(<link rel="apple-touch-icon" href="#{logo}">\n)
      end
      io << STYLESHEETS << "\n" << IMPORTMAP << "\n"
      # Custom CSS аккаунта (custom_styles_tag: <style> в head)
      if account && (styles = account.custom_styles.to_s) != ""
        io << "<style>\n" << styles << "\n</style>\n"
      end
      if chat && room_id
        io << %(<meta name="turbo-cache-control" content="no-preview">\n)
        io << %(<meta name="current-room-id" content="#{room_id}">\n)
      end
      io << head_extra
      io << "</head>\n"
    end
  end

  # <body> + nav#nav — порт rooms/show/_nav.html.erb: чип текущей
  # комнаты (btn--reversed room--current), кнопка настроек с иконкой
  # menu-dots-horizontal, колокольчик вовлечённости. Direct-комнаты
  # (name NULL): room_display_name — имена остальных участников.
  def self.body_open(room : Room? = nil, viewer : User? = nil) : String
    String.build do |io|
      io << %(<body class="sidebar" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n)
      if r = room
        noun = "room"
        io << %(<span class="btn btn--reversed btn--faux room--current">)
        io << %(<h1 class="room__contents txt-medium overflow-ellipsis">)
        if r.name.nil?
          noun = "Ping"
          members = User.where(
            %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), r.id.not_nil!)
            .order("id").to_a
            .reject { |m| viewer && m.id == viewer.id }
          names = members.map(&.name.to_s)
          io << %(<span class="for-screen-reader">Ping with </span>)
          io << HTML.escape(sentence(names))
        else
          io << HTML.escape(r.name.to_s)
        end
        io << %(</h1></span>\n)
        io << %(<a class="btn" style="view-transition-name: edit-room-#{r.id}" )
        io << %(data-room-id="#{r.id}" href="/rooms/#{r.id}/edit">)
        io << %(<img aria-hidden="true" src="#{asset("menu-dots-horizontal.svg")}" width="20" height="20">)
        io << %(<span class="for-screen-reader">Settings for this #{noun}</span></a>\n)
        io << involvement_bell(r, viewer)
      end
      io << "</nav>\n"
      io << %(<main id="main-content">\n)
    end
  end

  # Колокольчик вовлечённости (rooms/involvements/_bell.html.erb +
  # Rooms::InvolvementsHelper#button_to_change_involvement) — статическое
  # состояние из memberships.involvement текущего юзера (роута
  # room_involvement в приложении нет, клик не циклит состояния).
  private def self.involvement_bell(room : Room, viewer : User?) : String
    return "" unless viewer
    membership = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, viewer.id.not_nil!).take
    return "" unless membership
    involvement = membership.involvement.to_s.presence || "mentions"
    human = INVOLVEMENT_LABELS[involvement]? || involvement
    rid = room.id.not_nil!
    String.build do |io|
      io << %(<span>\n<span class="button_to_change_notifying">\n)
      io << %(<turbo-frame id="involvement_room_#{rid}">)
      io << %(<button class="btn #{involvement}" role="checkbox" aria-checked="true" tabindex="0">)
      io << %(<img src="#{asset("notification-bell-#{involvement}.svg")}" aria-hidden="true" width="20" height="20">)
      io << %(<span class="for-screen-reader" id="involvement_label_room_#{rid}">) << human << %(</span>)
      io << %(</button>\n</turbo-frame>\n</span>\n</span>\n)
    end
  end

  INVOLVEMENT_LABELS = {
    "mentions"   => "Notifying about @ mentions",
    "everything" => "Notifying about all messages",
    "nothing"    => "Notifications are off",
    "invisible"  => "Notifications are off and room invisible in sidebar",
  }

  # to_sentence: "A, B and C"
  private def self.sentence(parts : Array(String)) : String
    case parts.size
    when 0 then ""
    when 1 then parts.first
    when 2 then "#{parts[0]} and #{parts[1]}"
    else        parts[0..-2].join(", ") + " and " + parts[-1]
    end
  end

  # ===== Страничный layout не-chat экранов (layout_start.eta/layout_end.eta)

  # <img>-иконка из пребилда ассетов референса.
  def self.icon(name : String, size : Int32 = 20, cls : String? = nil) : String
    c = cls ? %( class="#{cls}") : ""
    %(<img src="#{asset(name)}" aria-hidden="true" width="#{size}" height="#{size}"#{c}>)
  end

  # nav-кнопка «Go Back» (layout_start.eta: form-экраны).
  def self.nav_back(path : String) : String
    %(<div class="flex-item-justify-start"><a class="btn" href="#{path}">) +
      icon("arrow-left.svg") +
      %(<span class="for-screen-reader">Go Back</span></a></div>)
  end

  # head + <body class=screen(+admin)> + nav + main — layout_start для
  # form/account/profile/bots/... экранов.
  def self.page_open(screen : String, title : String, user : User?,
                     body_class : String? = nil, nav_html : String = "",
                     head_extra : String = "") : String
    cls = (body_class || screen).to_s
    cls += " admin" if user && user.role == 1
    String.build do |io|
      io << head(title, user, nil, chat: false, head_extra: head_extra)
      io << %(<body class="#{cls}" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n) << nav_html << %(</nav>\n)
      io << %(<main id="main-content">\n)
    end
  end

  # footer(+composer/version) + aside + app-logo — layout_end.eta.
  def self.page_close(footer_html : String = "", sidebar_html : String = "") : String
    String.build do |io|
      io << %(<footer id="footer">) << footer_html << %(</footer></main>\n)
      io << %(<aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">)
      io << sidebar_html << "</aside>\n"
      io << %(<a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">)
      io << %(<img alt="Campfire logo" src="#{asset("campfire-icon.png")}" width="256" height="216"></a>\n)
      io << %(</body></html>\n)
    end
  end

  # Кнопка-иконка QR (transfer_link.eta/invite.eta: lightbox + qr-code.svg).
  def self.qr_button(url : String) : String
    %(<a href="#{url}" class="btn" data-lightbox-target="image" ) +
      %(data-action="lightbox#open" data-lightbox-url-value="#{url}">) +
      %(<span class="for-screen-reader">Show QR code</span>) +
      icon("qr-code.svg", 20, "colorize--black") + %(</a>)
  end

  # Кнопка «копировать» (copy-to-clipboard + copy-paste.svg).
  def self.copy_button(content : String, sr_label : String) : String
    %(<button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" ) +
      %(data-copy-to-clipboard-success-class="btn--success" ) +
      %(data-copy-to-clipboard-content-value="#{HTML.escape(content)}">) +
      %(<span class="for-screen-reader">#{HTML.escape(sr_label)}</span>) +
      icon("copy-paste.svg", 20, "colorize--black flex-item-no-shrink") + %(</button>)
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
  # проходит подстрокой id="<cmid>"). Вложение (attachment) заменяет
  # rich-text тело (message_attachment_presentation).
  def self.message_dom(m : Message, room : Room, creator : User?,
                       attachment : Attachment? = nil) : String
    cid = m.client_message_id.to_s.presence || m.id.to_s
    mid = m.id.not_nil!
    creator_name = creator.try(&.name).to_s
    created = m.created_at || Time.utc
    updated = m.updated_at || created
    permalink = "/rooms/#{room.id}/@#{mid}"
    avatar_src = "/users/#{m.creator_id}/avatar"
    body_html = attachment ? attachment_presentation(attachment) : m.body.to_s
    emoji = all_emoji?(body_html) ? " message--emoji" : ""

    String.build do |io|
      io << %(<div id="message_#{cid}" class="message#{emoji}" data-controller="reply" )
      io << %(data-user-id="#{m.creator_id}" data-message-id="#{mid}" )
      io << %(data-message-timestamp="#{created.to_unix}" data-message-updated-at="#{updated.to_unix}" )
      io << %(data-sort-value="#{created.to_unix}" data-messages-target="message" )
      io << %(data-search-results-target="message" data-refresh-room-target="message" )
      io << %(data-reply-composer-outlet="#composer" data-client-message-id=") << HTML.escape(cid) << %(">\n)
      io << %(<h2 class="message__day-separator"><time datetime="#{created.to_rfc3339}" data-local-time-target="date"></time></h2>\n)
      io << %(<figure class="avatar message__avatar"><a title=") << HTML.escape(creator_name)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/#{m.creator_id}">)
      io << %(<img aria-hidden="true" src="#{avatar_src}" width="48" height="48" loading="lazy"></a></figure>\n)
      io << %(<turbo-frame id="edit_message_#{cid}"><div class="message__body"><div class="message__body-content">)
      io << %(<div class="message__meta"><h3 class="message__heading">)
      io << %(<span class="message__author" title=") << HTML.escape(creator_name)
      io << %("><strong data-reply-target="author">) << HTML.escape(creator_name) << %(</strong></span>)
      io << %(<a target="_top" class="message__permalink" href="#{permalink}">)
      io << %(<time class="message__timestamp" datetime="#{created.to_rfc3339}" data-local-time-target="time"></time></a>)
      io << %(<span class="message__room"> <a target="_top" data-reply-target="link" href="#{permalink}">)
      io << HTML.escape(room.name.to_s) << %(</a></span>)
      io << %(</h3>\n)
      io << message_actions(mid, cid, permalink, room)
      io << %(</div>\n)
      io << %(<div id="presentation_message_#{cid}" dir="auto" data-reply-target="body" data-messages-target="body">)
      io << %(<div class="lexxy-content">) << body_html << %(</div></div>\n)
      io << %(</div></div></turbo-frame></div>\n)
    end
  end

  # message--emoji: непустой plain text без букв и цифр (express allEmoji:
  # !!plain && !/[\p{L}\p{N}]/u) — только эмодзи/пунктуация; класс даёт
  # крупный шрифт (messages.css .message--emoji).
  private def self.all_emoji?(body_html : String?) : Bool
    return false unless html = body_html
    text = html.gsub(/<[^>]*>/, " ")
    text = text.gsub("&nbsp;", " ").gsub("&amp;", "&").gsub("&lt;", "<")
      .gsub("&gt;", ">").gsub("&quot;", "\"").gsub("&#39;", "'")
    saw_char = false
    text.each_char do |c|
      next if c.whitespace?
      saw_char = true
      return false if c.letter? || c.number?
    end
    saw_char
  end

  # ===== Вложения сообщений (ActiveStorage, storage.js) =====

  # Вложение сообщения: blob + имя файла (батч-загрузка одним IN).
  struct Attachment
    property blob_id : Int64
    property filename : String
    property content_type : String
    property key : String

    def initialize(@blob_id, @filename, @content_type, @key)
    end

    def image? : Bool
      content_type.starts_with?("image/")
    end

    def video? : Bool
      content_type.starts_with?("video/")
    end
  end

  # attachment-блобы для списка сообщений одним запросом.
  def self.attachments_for(message_ids : Array(Int64)) : Hash(Int64, Attachment)
    table = {} of Int64 => Attachment
    return table if message_ids.empty?
    placeholders = message_ids.map { "?" }.join(", ")
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT a.record_id, b.id, b.filename, b.content_type, b.key
        FROM active_storage_attachments a
        JOIN active_storage_blobs b ON b.id = a.blob_id
        WHERE a.record_type = 'Message' AND a.record_id IN (#{placeholders})),
      args: message_ids, as: {Int64, Int64, String, String, String})
    rows.each { |(mid, bid, filename, ct, key)| table[mid] = Attachment.new(bid, filename, ct, key) }
    table
  end

  def self.storage_verifier
    CRails.application.message_verifier("ActiveStorage",
      digest: :sha1, url_safe: true)
  end

  # /rails/active_storage/blobs/redirect/<signed blob_id>/<filename>
  def self.blob_url(a : Attachment) : String
    token = storage_verifier.generate(a.blob_id, purpose: "blob_id")
    "/rails/active_storage/blobs/redirect/#{token}/#{URI.encode_path_segment(a.filename)}"
  end

  # /rails/active_storage/representations/redirect/<blob_id>/<variation>/<filename>
  # (transforms как у express: format из расширения, 1200×800)
  def self.representation_url(a : Attachment) : String
    token = storage_verifier.generate(a.blob_id, purpose: "blob_id")
    ext = File.extname(a.filename).lchop('.')
    format = ext.empty? ? "png" : ext
    variation = storage_verifier.generate(
      %({"format":"#{format}","resize_to_limit":[1200,800]}), purpose: "variation")
    "/rails/active_storage/representations/redirect/#{token}/#{variation}/#{URI.encode_path_segment(a.filename)}"
  end

  # message_attachment_presentation (rendering.js): картинка — lightbox + img,
  # видео — video, остальное — ссылка на скачивание.
  def self.attachment_presentation(a : Attachment) : String
    url = blob_url(a)
    if a.image?
      repr = representation_url(a)
      %(<a href="#{url}" data-lightbox-target="image" data-action="lightbox#open" ) +
        %(data-lightbox-url-value="#{url}?disposition=attachment">) +
        %(<img class="message__attachment" src="#{repr}" alt="#{HTML.escape(a.filename)}" loading="lazy"></a>)
    elsif a.video?
      %(<video src="#{url}" poster="#{representation_url(a)}" controls class="message__attachment"></video>)
    else
      %(<a href="#{url}?disposition=attachment">#{HTML.escape(a.filename)}</a>)
    end
  end

  # message_actions.eta (ядро): summary-меню с иконками Reply / Copy
  # link / Edit (quick-boosts и attachment-действия не портированы —
  # нет роутов /messages/:id/boosts и blob-путей).
  private def self.message_actions(mid : Int64, cid : String, permalink : String, room : Room) : String
    String.build do |io|
      io << %(<div class="message__actions"><details class="position-relative" data-controller="popup" )
      io << %(data-popup-orientation-top-class="popup-orientation-top" )
      io << %(data-action="keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside">)
      io << %(<summary class="btn message__action-btn message__options-btn">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("menu-dots-horizontal.svg")}" width="20" height="20">)
      io << %(<span class="for-screen-reader">Message options</span></summary>)
      io << %(<div class="message__actions-menu border shadow" data-popup-target="menu">)
      io << %(<div class="flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid">)
      io << %(<button class="btn message__action-btn center full-width" data-action="reply#reply" )
      io << %(title="Reply" aria-label="Reply">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("reply.svg")}" width="20" height="20"></button>\n)
      io << %(<button class="btn message__action-btn center full-width" title="Copy link" aria-label="Copy link" )
      io << %(data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" )
      io << %(data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-url-value="#{permalink}">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("link.svg")}" width="20" height="20"></button>\n)
      io << %(<a class="btn message__action-btn center full-width message__edit-btn" data-turbo-frame="edit_message_#{cid}" )
      io << %(title="Edit" aria-label="Edit" href="/rooms/#{room.id}/messages/#{mid}/edit">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("pencil.svg")}" width="20" height="20"></a>)
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

    # Вложения одним IN-запросом (attachment → blob, без N+1).
    attachments = attachments_for(messages.map(&.id.not_nil!))

    messages.each do |m|
      if (html = hits[m.id.not_nil!]?)
        io << html
      elsif (r = rooms[m.room_id.not_nil!]?)
        html = message_dom(m, r, creators[m.creator_id.not_nil!]?,
          attachments[m.id.not_nil!]?)
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

  # composer.eta / rooms/show/_composer.html.erb — форма отправки
  # сообщения (lexxy-editor). Иконки: search (контекст-кнопка),
  # messages-outlined (хинт слева от поля), attachment, text-options,
  # arrow-up (send).
  def self.composer(room : Room) : String
    String.build do |io|
      io << %(<div class="composer flex align-end gap position-relative" data-controller="typing-notifications" )
      io << %(data-typing-notifications-active-class="typing-indicator--active">\n)
      io << %(<a class="btn flex-item-no-shrink margin-block-end composer__context-btn" style="view-transition-name: input-switcher" href="/searches">)
      io << %(<img aria-hidden="true" src="#{asset("search.svg")}" width="20" height="20">)
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
      io << %(<img aria-hidden="true" class="composer__input-hint colorize--black" style="view-transition-name: input-btn;" )
      io << %(src="#{asset("messages-outlined.svg")}" width="22" height="22">\n)
      io << %(<div class="flex flex-column flex-item-grow min-width gap">\n)
      io << %(<lexxy-editor rows="1" class="input lexxy-content" style="order: -1" aria-multiline="true" aria-label="Write a message" )
      io << %(permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" )
      io << %(data-action="lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft" )
      io << %(data-composer-target="text" id="message_body" name="message[body]">)
      io << %(<lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id=#{room.id}" remote-filtering="true" empty-results="No matches"></lexxy-prompt>)
      io << %(</lexxy-editor>\n</div>\n)
      io << %(<label class="btn btn--borderless txt-small flex-item-no-shrink composer__attachment-btn input--file">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("attachment.svg")}" width="22" height="22">)
      io << %(<input type="file" data-action="composer#filePicked" multiple>)
      io << %(<span class="for-screen-reader">Attach a file</span></label>\n)
      io << %(<button class="btn btn--borderless txt-small flex-item-no-shrink composer__rich-text-btn" type="button" data-action="composer#toggleToolbar">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("text-options.svg")}" width="20" height="20">)
      io << %(<span class="for-screen-reader">Rich text</span></button>\n)
      io << %(<button name="send" type="submit" data-action="composer#submit" class="btn btn--reversed flex-item-no-shrink txt-small">)
      io << %(<img aria-hidden="true" src="#{asset("arrow-up.svg")}" width="20" height="20">)
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
      io << %(data-format-message-target="message" data-pending-message="true" )
      io << %(data-client-message-id="$clientMessageId$" data-user-id="#{user.id}" )
      io << %(data-message-timestamp="$messageTimestamp$" data-messages-target="message">\n)
      io << %(<div class="message__day-separator"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="date"></time></div>\n)
      io << %(<figure class="avatar message__avatar"><a title=") << HTML.escape(user.name.to_s)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/#{user.id}">)
      io << %(<img aria-hidden="true" src="/users/#{user.id}/avatar" width="48" height="48"></a></figure>\n)
      io << %(<div class="message__body"><div class="message__body-content"><div class="message__meta">)
      io << %(<h3 class="message__heading"><span class="message__author"><strong>)
      io << HTML.escape(user.name.to_s) << %(</strong></span>)
      io << %(<span class="message__permalink"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="time"></time></span>)
      io << %(</h3>\n)
      io << %(<div class="message__actions"><div class="position-relative">)
      io << %(<span class="btn message__action-btn message__options-btn">)
      io << %(<img class="colorize--black" aria-hidden="true" src="#{asset("menu-dots-horizontal.svg")}" width="20" height="20">)
      io << %(<span class="for-screen-reader">Message options</span></span>)
      io << %(</div></div>\n)
      io << %(</div>\n)
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
