# ChatLayout: shared page shell for Campfire (port of layout_start/
# layout_end/composer/message_uncached from the express templates; JS/CSS
# is the reference prebuild in public/assets, fragments in app/views/*.html).
module ChatLayout
  STYLESHEETS = {{ read_file "#{__DIR__}/../views/stylesheets.html" }}
  IMPORTMAP   = {{ read_file "#{__DIR__}/../views/importmap.html" }}

  # Named routes in a static context: the same name table as the
  # controllers' *_path helpers (Routes::UrlHelpers), but without an
  # instance — a direct RouteSet#path_for call. Output is byte-identical
  # to the former string interpolations.
  def self.route_path(name : String, *values) : String
    CRails.application.routes.path_for(name, values.map(&.to_s).to_a)
  end

  # file_uploader.js reads meta[name=csrf-token] before fetch; the server
  # does not verify CSRF, so a stable per-process value is enough.
  CSRF_TOKEN = Random::Secure.hex(32)
  # config/initializers/vapid.rb — bench app credentials (deterministic).
  VAPID_PUBLIC_KEY = "BIoPd4akjKCmMf6bLDelJ40J5QnaHtttIHNVqfnhiWpR9Vd-9oJxGb7IuVDO3v4dEzJBzWLXOYTo8KHZO3Y_vtY="

  # asset("arrow-up.svg") -> "/assets/arrow-up-f96b3895.svg" (reference
  # prebuild manifest).
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

  # Rails SignedGlobalID: signs "gid://campfire/User/<id>?expires_in" with
  # the "signed_global_ids" key, purpose "attachable" (rails.js sgid).
  # Shared by the controller and the jbuilder partials, hence it lives in
  # ChatLayout.
  def self.attachable_sgid(user_id : Int64) : String
    secret = ENV["SECRET_KEY_BASE"]? ||
             raise RuntimeError.new("SECRET_KEY_BASE is not configured")
    key = ActiveSupport::CachingKeyGenerator.new(
      ActiveSupport::KeyGenerator.new(secret, iterations: 1000, digest: :sha1))
      .generate_key("signed_global_ids")
    verifier = ActiveSupport::MessageVerifier.new(key, url_safe: true, digest: :sha1)
    verifier.generate("gid://campfire/User/#{user_id}?expires_in",
      purpose: "attachable")
  end

  # ISO-8601 UTC with milliseconds — the reference's Date#toISOString()
  # format and Rails Time#to_json (bots API jbuilder views; also used
  # from JbuilderTemplate partials with no controller context).
  def self.iso8601_ms(time : Time) : String
    time.to_utc.to_s("%Y-%m-%dT%H:%M:%S.%LZ")
  end

  def self.fresh_account_logo_path(account : Account?, size : String? = nil) : String
    return "/account/logo" unless account
    query = [] of String
    if (stamp = account.updated_at.try(&.to_s("%Y%m%d%H%M%S")))
      query << "v=#{stamp}"
    end
    query << "size=#{size}" if size
    query.empty? ? "/account/logo" : "/account/logo?#{query.join("&")}"
  end

  # user is Current.user (set by ApplicationController before render;
  # reset by the dispatcher between requests, as in Rails).
  def self.head(title : String, room_id : Int64?, chat : Bool,
                head_extra : String = "") : String
    user = Current.user
    String.build do |io|
      io << "<!DOCTYPE html>\n<html>\n<head>\n<title>" << HTML.escape(title) << "</title>\n"
      io << %(<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">\n)
      # layouts/application.html.erb:7-21 — exact meta tag order.
      # csp_meta_tag is empty (CSP not configured); Rails emits no
      # csrf-token meta (form protection relies on Sec-Fetch-Site, no
      # tokens).
      io << %(<meta name="view-transition" content="same-origin">\n)
      io << %(<meta name="color-scheme" content="light dark">\n)
      io << %(<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">\n)
      io << %(<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">\n)
      io << %(<meta name="apple-mobile-web-app-capable" content="yes">\n)
      if u = user
        # current_user_meta_tags: safe_join with no separator — both meta
        # tags on one line; Rails writes them via tag.meta self-closing.
        io << %(<meta name="current-user-id" content="#{u.id}"/>)
        io << %(<meta name="current-user-name" content=") << HTML.escape(u.name.to_s) << %("/>\n)
      end
      io << %(<meta name="action-cable-url" content="/cable">\n)
      io << %(<meta name="vapid-public-key" content="#{VAPID_PUBLIC_KEY}">\n)
      io << %(<meta name="turbo-prefetch" content="true">\n)
      # tag.link manifest/icon/apple-touch-icon → fresh_account_logo
      account = Account.take
      if account
        logo = fresh_account_logo_path(account)
        io << %(<link rel="manifest" href="/webmanifest.json">\n)
        io << %(<link rel="icon" href="#{logo}" type="image/png">\n)
        io << %(<link rel="apple-touch-icon" href="#{logo}">\n)
      end
      io << STYLESHEETS << "\n"
      # custom_styles_tag — before the importmap (layouts/application.html.erb:30-32)
      if account && (styles = account.custom_styles.to_s) != ""
        io << %(<style data-turbo-track="reload">) << styles << %(</style>\n)
      end
      io << IMPORTMAP << "\n"
      if chat && room_id
        io << %(<meta name="turbo-cache-control" content="no-preview">\n)
        io << %(<meta name="current-room-id" content="#{room_id}">\n)
      end
      io << head_extra
      io << "</head>\n"
    end
  end

  # <body> + nav#nav — port of rooms/show/_nav.html.erb: current room
  # chip (btn--reversed room--current), settings button with the
  # menu-dots-horizontal icon, involvement bell. Direct rooms
  # (name NULL): room_display_name — the other members' names.
  def self.body_open(room : Room? = nil,
                     ua : String = "", origin : String = "") : String
    viewer = Current.user
    String.build do |io|
      cls = viewer && viewer.role == 1 ? "sidebar admin" : "sidebar"
      io << %(<body class="#{cls}" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n)
      if r = room
        noun = "room"
        io << %(<span class="btn btn--reversed btn--faux room--current">\n)
        io << %(<h1 class="room__contents txt-medium overflow-ellipsis">\n)
        if r.name.nil?
          noun = "Ping"
          members = User.where(
            %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), r.id.not_nil!)
            .order("id").to_a
            .reject { |m| viewer && m.id == viewer.id }
          names = members.map(&.name.to_s)
          io << %(<span class="for-screen-reader">Ping with</span>\n)
          io << HTML.escape(sentence(names)) << "\n"
        else
          io << HTML.escape(r.name.to_s) << "\n"
        end
        io << %(</h1>\n</span>\n)
        io << %(<a class="btn" data-room-id="#{r.id}" href="#{room_edit_path(r)}" )
        io << %(style="view-transition-name: edit-room-#{r.id}">\n)
        io << %(<img aria-hidden="true" height="20" src="#{asset("menu-dots-horizontal.svg")}" width="20">\n)
        io << %(<span class="for-screen-reader">Settings for this #{noun}</span>\n</a>\n)
        io << involvement_bell(r, viewer, ua: ua, origin: origin)
      end
      io << "</nav>\n"
      io << %(<main id="main-content">\n)
    end
  end

  # Oracle edit_room_path(room): STI-polymorphic route segment
  # (rooms/opens|directs|closeds). The port writes both short ('Open')
  # and full ('Rooms::Open') type values — the seed uses full, rooms
  # created via the port use short.
  def self.room_edit_path(room : Room) : String
    seg = case room.type.to_s.split("::").last?.to_s
          when "Direct" then "directs"
          when "Closed" then "closeds"
          else "opens"
          end
    "/rooms/#{seg}/#{room.id}/edit"
  end

  # Involvement bell — rooms/involvements/_bell.html.erb (ChatERB):
  # turbo-frame /rooms/N/involvement + notifications controller +
  # pwa instruction dialogs (UA-dependent partials).
  private def self.involvement_bell(room : Room, viewer : User?,
                                    ua : String = "", origin : String = "") : String
    return "" unless viewer
    membership = Membership.where(
      "room_id = ? AND user_id = ?", room.id.not_nil!, viewer.id.not_nil!).take
    return "" unless membership
    involvement = membership.involvement.to_s.presence || "mentions"
    ChatERB.new(room: room, involvement: involvement, origin: origin,
      ua: ua).bell.to_s
  end

  INVOLVEMENT_LABELS = {
    "mentions"   => "Notifying about @ mentions",
    "everything" => "Notifying about all messages",
    "nothing"    => "Notifications are off",
    "invisible"  => "Notifications are off and room invisible in sidebar",
  }

  # to_sentence (Rails default): "A", "A and B", "A, B, and C"
  private def self.sentence(parts : Array(String)) : String
    case parts.size
    when 0 then ""
    when 1 then parts.first
    when 2 then "#{parts[0]} and #{parts[1]}"
    else        parts[0..-2].join(", ") + ", and " + parts[-1]
    end
  end

  # ===== Page layout for non-chat screens (layout_start.eta/layout_end.eta)

  # <img> icon from the reference asset prebuild. size=nil means no
  # width/height (Rails image_tag without size). Delegates to the static
  # AssetTagHelper.image_tag; the wire bytes are `<img src width height
  # aria-hidden class />` (attribute order and the self-closing slash are
  # normalized by the artifacts' browser serialization, see
  # harness/normalize.rb — DOM-equivalent to the previous raw string).
  def self.icon(name : String, size : Int32? = 20, cls : String? = nil) : String
    # Object-union: the nested aria Hash is Hash(String, String), which
    # does not fit Hash(String, AttrVal) (generic invariance); the static
    # image_tag normalizes the values itself.
    opts = {} of String => String | Hash(String, String)
    opts["aria"] = {"hidden" => "true"}
    opts["size"] = "#{size}x#{size}" if size
    opts["class"] = cls if cls
    ::ActionView::Helpers::AssetTagHelper.image_tag(asset(name), opts).to_s
  end

  # nav "Go Back" button (layout_start.eta: form screens). Line breaks
  # as in the Rails ERB output (artifacts: <div>/<a>/</div> on separate
  # lines).
  def self.nav_back(path : String) : String
    %(<div class="flex-item-justify-start">\n<a class="btn" href="#{path}">) +
      icon("arrow-left.svg") +
      %(<span class="for-screen-reader">Go Back</span></a>\n</div>)
  end

  # head + <body class=body_class(+admin)> + nav + main — layout_start
  # for form/account/profile/bots/... screens. In the reference only a
  # few pages set @body_class (rooms/show: sidebar, searches:
  # sidebar searches, signup screens: signup) — no other classes exist.
  def self.page_open(screen : String, title : String,
                     body_class : String? = nil, nav_html : String = "",
                     head_extra : String = "") : String
    user = Current.user
    cls = body_class.to_s
    # Oracle body_classes: [body_class, admin].compact.join(" ") — no
    # leading space when body_class is empty.
    if user && user.role == 1
      cls = cls.empty? ? "admin" : "#{cls} admin"
    end
    String.build do |io|
      io << head(title, nil, chat: false, head_extra: head_extra)
      io << %(<body class="#{cls}" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n) << nav_html << %(\n</nav>\n)
      io << %(<main id="main-content">\n)
    end
  end

  # footer(+composer/version) + aside + app-logo —
  # layouts/_body_close.html.erb (ChatERB).
  def self.page_close(footer_html : String = "", sidebar_html : String = "") : String
    ChatERB.new(footer: footer_html, sidebar: sidebar_html).body_close.to_s
  end

  # QR icon button (transfer_link.eta/invite.eta: lightbox + qr-code.svg).
  def self.qr_button(url : String) : String
    %(<a href="#{url}" class="btn" data-lightbox-target="image" ) +
      %(data-action="lightbox#open" data-lightbox-url-value="#{url}">) +
      %(<span class="for-screen-reader">Show QR code</span>) +
      icon("qr-code.svg", 20, "colorize--black") + %(</a>)
  end

  # Copy button (copy-to-clipboard + copy-paste.svg) —
  # button_to_copy_to_clipboard: the icon/sr-text order and the img class
  # are decided by the caller (bots: img first without a class;
  # profile/invite: span first with colorize--black).
  def self.copy_button(content : String, sr_label : String,
                       icon_class : String? = nil, icon_first : Bool = false) : String
    icon_html = icon("copy-paste.svg", 20, icon_class)
    span_html = %(<span class="for-screen-reader">#{HTML.escape(sr_label)}</span>)
    inner = (icon_first ? [icon_html, span_html] : [span_html, icon_html]).join('\n')
    %(<button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" ) +
      %(data-copy-to-clipboard-success-class="btn--success" ) +
      %(data-copy-to-clipboard-content-value="#{HTML.escape(content)}">\n) +
      inner + %(\n</button>)
  end

  # web-share (transfer block of profile/invite/user): share the
  # auto-login link; the button is hidden, Stimulus reveals it when
  # navigator.share is supported. The caller appends the "    </div>"
  # tail (artifacts).
  def self.web_share_button(url : String) : String
    %(<button class="btn" data-action="web-share#share" data-controller="web-share" ) +
      %(data-web-share-text-value="This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out." ) +
      %(data-web-share-title-value="Your sign-in link" ) +
      %(data-web-share-url-value="#{HTML.escape(url)}" hidden="">\n) +
      %(<span class="for-screen-reader">Share auto-login link</span>\n) +
      icon("share.svg", 20, "flex-item-no-shrink colorize--black") +
      %(\n</button>)
  end

  # rooms/show/_invitation.html.erb + accounts/_invite.html.erb — the
  # "Welcome to Campfire" block above the original room's messages
  # (Room.original, while it has no more than PAGE_SIZE messages):
  # account logo, invite_message translation, the invite-link field with
  # QR/copy/sharing and join-code regeneration for admins.
  def self.system_welcome(origin : String) : String
    user = Current.user
    return "" unless user
    account = Account.take
    join_url = "#{origin}/join/#{account.try(&.join_code).to_s}"
    qr_path = "/qr_code/" + Base64.urlsafe_encode(join_url, padding: false)
    String.build do |io|
      io << %(<div id="system_welcome" class="message message--formatted txt-align-center center">\n)
      io << %(<div class="message__body center">\n)
      io << %(<div class="message__body-content position-relative">\n)
      # account_logo_tag style: "center margin-block-end txt-large"
      io << %(<figure class="account-logo avatar center margin-block-end txt-large">)
      io << %(<img alt="Account logo" src="#{fresh_account_logo_path(account)}" width="300" height="300"></figure>\n)
      io << %(<div class="flex align-center gap">\n)
      io << %(<div class="system-welcome--translation">\n)
      io << TranslationsHelper.translation_button("invite_message") << "\n"
      io << %(</div>\n)
      io << %(<p>\n<strong>Welcome to Campfire</strong><br>\n)
      io << %(To invite people to chat, share the join link below.\n</p>\n)
      io << %(</div>\n)
      # accounts/_invite.html.erb (line breaks as in the Rails ERB output)
      io << %(<div class="flex flex-column align-center gap">\n)
      io << %(<label class="flex flex-column gap full-width" style="--row-gap: 0.5em">\n)
      io << %(<strong id="invite_label" class="invite-label">Share to invite more people</strong>\n)
      io << %(<span class="flex align-center gap input input--actor fill-white">\n)
      io << icon("person-add.svg", 20, "colorize--black") << "\n"
      io << %(<input type="text" class="input" id="invite_url" value="#{HTML.escape(join_url)}" aria-labelledby="invite_label" readonly>\n)
      io << %(</span>\n)
      io << %(</label>\n)
      io << %(<div class="flex align-center gap">\n)
      io << %(<a href="#{qr_path}" class="btn" data-lightbox-target="image" ) <<
        %(data-action="lightbox#open" data-lightbox-url-value="#{qr_path}">\n)
      io << %(<span class="for-screen-reader">Show join link QR code</span>\n)
      io << icon("qr-code.svg", 20, "colorize--black") << "\n"
      io << %(</a>\n)
      # button_to_copy_to_clipboard
      io << %(<button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" ) <<
        %(data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="#{HTML.escape(join_url)}">\n)
      io << %(<span class="for-screen-reader">Copy join link</span>\n)
      io << icon("copy-paste.svg", 20, "colorize--black") << "\n"
      io << %(</button>\n)
      io << %(<button class="btn" hidden data-controller="web-share" data-action="web-share#share" ) <<
        %(data-web-share-url-value="#{HTML.escape(join_url)}" ) <<
        %(data-web-share-text-value="Hit this link to join me in Campfire and start chatting." ) <<
        %(data-web-share-title-value="Link to join Campfire">\n)
      io << %(<span class="for-screen-reader">Share join link</span>\n)
      io << icon("share.svg", 20, "colorize--black") << "\n"
      io << %(</button>\n)
      if user.role == 1
        io << %(<form action="/account/join_code" class="button_to" method="post"><button class="btn btn--regenerate" type="submit">\n)
        io << icon("refresh.svg", 20, "colorize--black") << "\n"
        io << %(<span class="for-screen-reader">Regenerate join link</span>\n)
        io << %(</button></form>  </div>\n)
      else
        io << %(</div>\n)
      end
      io << %(</div>\n)
      io << %(</div>\n</div>\n</div>\n)
    end
  end

  # Layout lightbox dialog (all pages, after </aside>): image viewer
  # dialog with close/download/share buttons.
  def self.lightbox_dialog : String
    String.build do |io|
      io << %(<dialog aria-label="Image Viewer (Press escape to close)" class="lightbox" )
      io << %(data-action="close-&gt;lightbox#reset" data-lightbox-target="dialog">\n)
      io << %(<img class="lightbox__image" data-lightbox-target="zoomedImage" src="">\n)
      io << %(<form class="lightbox__btn" method="dialog">\n<button class="btn">\n)
      io << icon("remove.svg", size: nil) << "\n"
      io << %(<span class="for-screen-reader">Close image viewer</span>\n</button>\n</form>\n)
      io << %(<a class="lightbox__btn--download btn hide-in-ios-pwa" data-lightbox-target="download" href="">\n)
      io << icon("download.svg", size: nil) << "\n"
      io << %(<span class="for-screen-reader">Download file</span>\n</a>\n)
      io << %(<button class="lightbox__btn--share btn"\n)
      io << %(data-controller="web-share"\ndata-action="web-share#share"\n)
      io << %(data-web-share-files-value=""\n)
      io << %(data-lightbox-target="share">\n)
      io << icon("share.svg", size: nil) << "\n"
      io << %(<span class="for-screen-reader">Share file</span>\n</button>\n</dialog>\n)
    end
  end

  # footer + sidebar (turbo-frame user_sidebar) + app-logo —
  # layouts/_body_close.html.erb. users/sidebar_helper.rb#
  # sidebar_turbo_frame_tag: turbo_frame_tag :user_sidebar with
  # target/data options (static FramesHelper form). The `->` in
  # data-action is escaped by tag_options as `-&gt;` — identical after
  # HTML parsing to the previous raw string (DOM normalization).
  def self.chat_sidebar_frame : String
    ::Turbo::FramesHelper.turbo_frame_tag("user_sidebar", "/users/me/sidebar", nil, {
      "target" => "_top",
      "data"   => {
        "turbo_permanent"         => true,
        "controller"              => "rooms-list read-rooms turbo-frame",
        "rooms_list_unread_class" => "unread",
        "action"                  => "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload",
      },
    }).to_s
  end

  # Oracle User#title: "name – bio" (bio may be NULL).
  def self.user_title(name : String?, bio : String?) : String
    bio.to_s.empty? ? name.to_s : "#{name} – #{bio}"
  end

  # fresh_user_avatar_path (oracle avatars_helper): public path
  # /users/<signed_id purpose=user/avatar>/avatar?v=<updated_at YYYYMMDDHHMMSS>.
  # The token is deterministic (shared secret) and byte-identical to the
  # Rails token.
  def self.fresh_user_avatar_path(user_id : Int64, updated_at : Time?) : String
    token = CRails.application
      .message_verifier("active_record/signed_id", url_safe: true)
      .generate(user_id, purpose: "user/avatar")
    stamp = (updated_at || Time.utc).to_s("%Y%m%d%H%M%S")
    "/users/#{token}/avatar?v=#{stamp}"
  end

  # room_display_name(room, for_user:) RoomsHelper for direct rooms:
  # the other members' names via to_sentence; empty (solo room) —
  # fallback (the viewer's name).
  def self.display_sentence(names : Array(String), fallback : String) : String
    joined = sentence(names)
    joined.empty? ? fallback : joined
  end

  # room_display_name(room, for_user: nil) RoomsHelper: regular rooms —
  # the name; direct (name NULL) — all members' names comma-joined.
  def self.room_display_name(room : Room) : String
    if room.direct?
      members = User.where(
        %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), room.id.not_nil!)
        .order("id").map(&.name.to_s)
      sentence(members)
    else
      room.name.to_s
    end
  end

  # avatar_tag of the oracle (users/avatars_helper): profile link,
  # 48x48 img by token path with cache-buster. loading is an image_tag
  # option (directs/edit passes loading: :lazy).
  def self.avatar_link(user : User?, loading : String? = nil) : String
    lazy = loading ? %( loading="#{loading}") : ""
    return %(<a class="btn avatar" data-turbo-frame="_top" href="/users/0"><img aria-hidden="true" src="/users/0/avatar" width="48" height="48"></a>) unless user
    uid = user.id.not_nil!
    String.build do |io|
      io << %(<a title=") << HTML.escape(user_title(user.name, user.bio))
      io << %(" class="btn avatar" data-turbo-frame="_top" href="#{route_path("user", uid)}">)
      io << %(<img aria-hidden="true"#{lazy} src="#{fresh_user_avatar_path(uid, user.updated_at)}" width="48" height="48"></a>)
    end
  end

  # One message boost for rendering (boost + booster in a single JOIN).
  struct BoostEntry
    attr_accessor id : Int64
    attr_accessor content : String
    attr_accessor booster_id : Int64
    attr_accessor booster_name : String
    attr_accessor booster_bio : String?
    attr_accessor booster_updated_at : Time?

    def initialize(@id, @content, @booster_id, @booster_name,
                   @booster_bio, @booster_updated_at)
    end
  end

  # Boosts for a message list in one query (includes(:booster)),
  # sorted by created_at (boosts.ordered).
  def self.boosts_for(message_ids : Array(Int64)) : Hash(Int64, Array(BoostEntry))
    table = {} of Int64 => Array(BoostEntry)
    return table if message_ids.empty?
    placeholders = message_ids.map { "?" }.join(", ")
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT b.message_id, b.id, b.content, b.booster_id, u.name, u.bio, u.updated_at
        FROM boosts b JOIN users u ON u.id = b.booster_id
        WHERE b.message_id IN (#{placeholders}) ORDER BY b.created_at),
      args: message_ids,
      as: {Int64, Int64, String, Int64, String, String?, Time?})
    rows.each do |(mid, bid, content, booster_id, name, bio, updated)|
      list = table[mid] ||= [] of BoostEntry
      list << BoostEntry.new(bid, content, booster_id, name, bio, updated)
    end
    table
  end

  # _presentation.html.erb: div id="presentation_message_<id>" with the
  # message body (turbo-stream replace target on edit). Text is wrapped
  # in the lexxy-content wrapper (layouts/action_text/contents/_content),
  # attachments are not (message_attachment_presentation).
  def self.presentation_dom(mid : Int64, body_html : String,
                            lexxy_wrapper : Bool = true) : String
    inner = lexxy_wrapper ? %(<div class="lexxy-content">\n) + body_html +
      (body_html.ends_with?("\n") ? "" : "\n") + %(</div>\n) : body_html + "\n"
    %(<div id="presentation_message_#{mid}" dir="auto" data-reply-target="body" data-messages-target="body">\n) +
      inner + %(</div>\n)
  end

  # Text presentation of a message: action-text-attachment rendering
  # (OG-embed from the content attribute, mention by sgid) + SANITIZE
  # (HtmlSanitizer — port of the oracle's final sanitize before
  # auto_link: tag/attribute allowlist, event handlers and javascript:
  # URLs stripped) + autolink URLs/emails (rails_autolink) + unwrapping
  # the table figure wrapper (in the reference DOM tables have no
  # lexxy-content__table-wrapper).
  # See MessagesHelper#message_presentation / auto_link_text.
  def self.text_presentation(body : String?) : String
    auto_link(HtmlSanitizer.sanitize(render_embeds(body.to_s)
      # The live lexxy editor puts data-highlight-language into the code
      # serialization when hljs is already loaded (a race at post time);
      # the baseline has no such attribute — strip it for deterministic
      # parity.
      .gsub(/ data-highlight-language="[^"]*"/, "")
      .gsub(%q{<figure class="lexxy-content__table-wrapper">}, "")
      .gsub("</figure>", "")))
  end

  # <action-text-attachment> -> final markup:
  #  * opengraph-embed: rendered by the action_text/attachables/
  #    _opengraph_embed partial (line breaks as in the ERB output;
  #    sanitize strips the figure/actiontext wrappers and rel, target
  #    stays). Data comes from the node attributes (filename/href/url/
  #    caption) or, for lexxy serializations, from the content markup
  #    (title anchor, description, img). Only absolute http(s) URLs on
  #    another host (web_url); a twitter avatar
  #    (pbs.twimg.com/profile_images) adds the og-embed--twitter-avatar
  #    modifier;
  #  * mention: sgid -> User -> span.mention (sanitize removes sgid and
  #    data-turbo-frame, so they are not rendered);
  #  * others: the content attribute as is.
  # Attribute values may contain raw ">", so the tag is parsed
  # character by character with quote handling, not by a regex.
  def self.render_embeds(body : String) : String
    outp = IO::Memory.new
    body = remove_solo_unfurled_link_text(body)
    cursor = 0
    # Byte indexing: parse_tag walks to_unsafe, byte_slice — String#index/
    # [] are char-based and break with a byte cursor on multibyte content
    # before the attachment
    while (start = body.byte_index("<action-text-attachment", cursor))
      attrs, tag_end = parse_tag(body, start)
      outp << body.byte_slice(cursor, start - cursor)
      if (close = body.byte_index("</action-text-attachment>", tag_end))
        content = attrs["content"]?
        content_type = attrs["content-type"]?
        sgid = attrs["sgid"]?
        if content_type.try(&.includes?("application/vnd.actiontext.opengraph-embed"))
          outp << opengraph_embed_dom(attrs, content)
        elsif content_type.try(&.includes?("application/vnd.campfire.mention")) && sgid
          outp << mention_dom(sgid.not_nil!)
        elsif content
          outp << unescape_entities(content.not_nil!)
        end
        cursor = close + "</action-text-attachment>".size
      else
        outp << body.byte_slice(start, tag_end - start)
        cursor = tag_end
      end
    end
    outp << body.byte_slice(cursor, body.bytesize - cursor)
    outp.to_s
  end

  # Parse a single tag: name/value pairs up to the real ">" (outside quotes).
  private def self.parse_tag(html : String, start : Int32) : {Hash(String, String), Int32}
    attrs = {} of String => String
    i = start + "<action-text-attachment".size
    while i < html.bytesize
      byte = html.to_unsafe[i]
      if byte == '>'.ord
        return {attrs, i + 1}
      elsif byte == ' '.ord || byte == '\n'.ord || byte == '\t'.ord || byte == '\r'.ord
        i += 1
        next
      end
      name_start = i
      while i < html.bytesize
        b = html.to_unsafe[i]
        break if b == '='.ord || b == ' '.ord || b == '>'.ord || b == '\n'.ord
        i += 1
      end
      name = html.byte_slice(name_start, i - name_start)
      value = ""
      if i < html.bytesize && html.to_unsafe[i] == '='.ord
        i += 1
        if i < html.bytesize && (html.to_unsafe[i] == '"'.ord || html.to_unsafe[i] == '\''.ord)
          quote = html.to_unsafe[i]
          i += 1
          vstart = i
          while i < html.bytesize && html.to_unsafe[i] != quote
            i += 1
          end
          value = html.byte_slice(vstart, i - vstart)
          i += 1
        else
          vstart = i
          while i < html.bytesize && (b = html.to_unsafe[i]) != ' '.ord && b != '>'.ord
            i += 1
          end
          value = html.byte_slice(vstart, i - vstart)
        end
      end
      attrs[name] = value unless name.empty?
    end
    {attrs, html.bytesize}
  end

  # Strips the wrappers removed by the Rails final sanitize:
  # figure.attachment…og, actiontext-opengraph-embed and the rel/target
  # attributes on anchors (not in allowed_attributes).
  private def self.strip_embed_wrappers(html : String) : String
    html.gsub(/<\/?figure\b[^>]*>/, "")
      .gsub(/<\/?actiontext-opengraph-embed\b[^>]*>/, "")
      .gsub(/\s(?:rel|target)="[^"]*"/, "")
      .strip
  end

  # ————— OG-embed: action_text/attachables/_opengraph_embed partial —————

  # ActionText::Attachment::OpengraphEmbed#web_url: only an absolute
  # http(s) URL on a domain (with a dot, no %-escaped host).
  private def self.og_web_url(value : String?) : String?
    return nil if (raw = value.to_s.strip).empty?
    return nil unless raw.starts_with?("http://", "https://")
    host = URI.parse(raw).host.to_s
    return nil if host.empty? || host.includes?("%") || !host.includes?(".")
    raw
  rescue
    nil
  end

  # attributes_from_node: node attributes (filename set) or parsing the
  # content markup (lexxy serializes the details into the attachment).
  private def self.og_attributes(attrs : Hash(String, String), content : String?)
    if (filename = attrs["filename"]?).to_s.empty?
      html = unescape_entities(content.to_s)
      title_html = html[/class=["']og-embed__title["'][^>]*>(.*?)<\/div>/m, 1]?.to_s
      {
        href:     og_web_url(title_html[/<a[^>]*\shref=["']([^"']*)["']/, 1]?),
        url:      og_web_url(html[/<img[^>]*\ssrc=["']([^"']*)["']/, 1]?),
        filename: title_html.gsub(/<[^>]*>/, "").strip,
        desc:     html[/class=["']og-embed__description["'][^>]*>([^<]*)</, 1]?.to_s.strip,
      }
    else
      {href:     og_web_url(attrs["href"]?),
       url:      og_web_url(attrs["url"]?),
       filename: filename,
       desc:     attrs["caption"]?.to_s}
    end
  end

  # Rails truncate(length:, omission: "…").
  private def self.truncate_ellipsis(text : String, length : Int32) : String
    return text if text.size <= length
    text[0, length - 1] + "…"
  end

  # _opengraph_embed.html.erb after sanitize: no figure/actiontext
  # wrappers, rel stripped, target="_blank" kept (allowed autolink).
  # Line breaks as in the ERB partial output.
  private def self.opengraph_embed_dom(attrs : Hash(String, String),
                                       content : String?) : String
    data = og_attributes(attrs, content)
    twitter = data[:url].to_s.starts_with?("https://pbs.twimg.com/profile_images")
    klass = twitter ? "og-embed gap og-embed--twitter-avatar" : "og-embed gap "
    title = truncate_ellipsis(HTML.escape(data[:filename].to_s), 280)
    desc = truncate_ellipsis(HTML.escape(data[:desc].to_s), 560)
    String.build do |io|
      io << "\n<div class=\"#{klass}\">\n"
      io << "<div class=\"og-embed__content\">\n<div class=\"og-embed__title\">\n"
      if (href = data[:href])
        # target="_blank" is added by the client (lexxy) in the DOM — the
        # Rails server output does not contain it.
        io << %(<a href="#{HTML.escape(href)}">) << title << %(</a>\n)
      else
        io << title << "\n"
      end
      io << "</div>\n"
      io << "<div class=\"og-embed__description\">" << desc << "</div>\n</div>\n"
      if (url = data[:url])
        io << "<div class=\"og-embed__image\">\n"
        io << %(<img src="#{HTML.escape(url)}" class="image center" alt="">\n)
        io << "</div>\n"
      end
      io << "</div>\n"
    end
  end

  # ContentFilters::RemoveSoloUnfurledLinkText: a single og-embed whose
  # plain body text equals its href (twitter URLs are normalized:
  # x.com -> twitter.com, query dropped) — the link text is removed.
  # Trix bodies (with a div): the div content is replaced by the single
  # attachment; otherwise paragraphs without an attachment are dropped.
  private def self.remove_solo_unfurled_link_text(body : String) : String
    spans = [] of {Int32, Int32}
    cursor = 0
    while (start = body.byte_index("<action-text-attachment", cursor))
      attrs, tag_end = parse_tag(body, start)
      close = body.byte_index("</action-text-attachment>", tag_end) || break
      if attrs["content-type"]?.to_s.includes?("application/vnd.actiontext.opengraph-embed")
        spans << {start, close + "</action-text-attachment>".size}
      end
      cursor = close + "</action-text-attachment>".size
    end
    return body unless spans.size == 1

    s, e = spans[0]
    attrs, _ = parse_tag(body, s)
    data = og_attributes(attrs, attrs["content"]?)
    return body unless (href = data[:href])

    plain = body.byte_slice(0, s) + body.byte_slice(e, body.bytesize - e)
    plain = plain.gsub(/<[^>]*>/, " ").gsub("&nbsp;", " ").gsub(/\s+/, " ").strip
    return body unless normalize_tweet_url(plain) == normalize_tweet_url(href)

    if body.includes?("<div")
      # rindex is char-based: search the byte prefix and convert the
      # index (there is usually no multibyte before the attachment, but
      # this is always correct)
      prefix = body.byte_slice(0, s)
      div_start = prefix.rindex("<div").try { |ci| prefix.char_index_to_byte_index(ci) }
      return body unless div_start
      content_start = body.byte_index(">", div_start).try(&. + 1) || return body
      div_end = body.byte_index("</div>", e) || return body
      body.byte_slice(0, content_start) +
        body.byte_slice(s, e - s) +
        "</div>" + body.byte_slice(div_end + "</div>".size, body.bytesize - div_end - "</div>".size)
    else
      body.gsub(/<p\b[^>]*>(.*?)<\/p>/m) do
        $~[1].includes?("<action-text-attachment") ? $~[0] : ""
      end
    end
  end

  # RemoveSoloUnfurledLinkText#normalize_tweet_url.
  private def self.normalize_tweet_url(url : String) : String
    return url unless url.includes?("x.com") || url.includes?("twitter.com")
    parsed = URI.parse(url)
    host = parsed.host.to_s.downcase == "x.com" ? "twitter.com" : parsed.host.to_s
    "#{parsed.scheme || "https"}://#{host}#{parsed.path}"
  rescue
    url
  end

  # users/_mention.html.erb after sanitize: span.mention with an avatar
  # (token path, ?v=) and the name; no sgid/data-turbo-frame.
  private def self.mention_dom(sgid : String) : String
    user = mention_user(sgid)
    return "" unless user
    uid = user.not_nil!.id.not_nil!
    String.build do |io|
      io << %(<span class="mention">)
      io << %(<a title=") << HTML.escape(user_title(user.name, user.bio))
      io << %(" class="btn avatar" href="#{route_path("user", uid)}" target="_top">)
      io << %(<img src="#{fresh_user_avatar_path(uid, user.updated_at)}" width="48" height="48"></a> )
      io << HTML.escape(user.name.to_s) << %(</span>)
    end
  end

  # sgid -> User — port of lib/rails_ext/action_text_attachables.rb
  # (attachable_from_possibly_expired_sgid): the signature is NOT
  # verified — SECRET_KEY_BASE rotation must not break existing User
  # mentions (ONLY User is permitted,
  # ATTACHABLES_PERMITTED_WITH_INVALID_SIGNATURES). The envelope comes
  # in two forms (AS MessageVerifier): new — {"data": <gid|b64>},
  # legacy (seed, Rails 7 Marshal) — {"message":
  # strict_b64(Marshal wrapper)}; the gid is extracted directly from
  # the marshal bytes (gid://campfire/<model>/<id>, no query), a full
  # Marshal parser is not needed.
  def self.mention_user(sgid : String) : User?
    message = sgid.split("--").first?
    return nil unless message
    encoded = decode_base64_lenient(message) || return nil
    envelope = JSON.parse(encoded)
    rails = envelope["_rails"]?
    data = rails.try &.["data"]?
    if data.nil? && (msg = rails.try &.["message"]?)
      inner = decode_base64_lenient(msg.to_s)
      data = inner.try &.[/gid:\/\/campfire\/[^\/]+\/\d+/]?
    end
    return nil unless data
    id = data.to_s[/\/User\/(\d+)/, 1]?.try(&.to_i64?)
    id.try { |i| User.find?(i) }
  rescue JSON::ParseException | Base64::Error | ArgumentError
    nil
  end

  private def self.decode_base64_lenient(text : String) : String?
    sanitized = text.tr("-_", "+/").gsub(/\s+/, "")
    sanitized += "=" * ((4 - sanitized.size % 4) % 4)
    Base64.decode_string(sanitized)
  rescue
    nil
  end

  # ————— Autolink (port of rails_autolink: auto_link_urls + emails) —————

  AUTO_LINK_RE = /(?:(?:(?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):\/\/|www\.\w)[^\s<\x{a0}"]+)/imx

  AUTO_EMAIL_RE = /(?<![\w.!#$%&'*\/=?^`{|}~+-])[\w.!#$%+-]\.?[\w.!#$%&'*\/=?^`{|}~+-]*@[\w-]+(?:\.[\w-]+)+/

  # escape_once: & is not doubled inside existing entities (Rails escape_once).
  private def self.escape_once(text : String) : String
    text.gsub(/&(?!#\d+;|#x[0-9a-fA-F]+;|[a-zA-Z][a-zA-Z0-9]*;)/, "&amp;")
      .gsub("<", "&lt;").gsub(">", "&gt;")
      .gsub('"', "&quot;").gsub("'", "&#39;")
  end

  def self.auto_link(text : String) : String
    auto_link_emails(auto_link_urls(text))
  end

  private def self.auto_link_urls(text : String) : String
    outp = IO::Memory.new
    cursor = 0
    while match = AUTO_LINK_RE.match_at_byte_index(text, cursor)
      # MatchData#begin/#end are char-based on this Crystal — convert to
      # byte offsets (the match_at_byte_index cursor is byte-based)
      m_begin = text.char_index_to_byte_index(match.begin.not_nil!).not_nil!
      href = match[0].not_nil!
      m_end = m_begin + href.bytesize
      # m_begin/m_end/cursor are byte-based; slices are byte-based too
      left = text.byte_slice(0, m_begin)
      right = text.byte_slice(m_end, text.bytesize - m_end)
      outp << text.byte_slice(cursor, m_begin - cursor)
      if auto_linked?(left, right)
        outp << href
      else
        # trailing punctuation is not part of the link (rails_autolink)
        punctuation = [] of String
        while (ch = href[-1]?) && !(ch.alphanumeric? || ch == '_' || ch == '/' || ch == '-' || ch == '=' || ch == ';')
          href = href[0...-1]
          punctuation << ch.to_s
          if opening = {"]" => "[", ")" => "(", "}" => "{"}[ch.to_s]?
            if href.count(opening) > punctuation.count(ch.to_s)
              href += punctuation.pop.to_s
              break
            end
          end
        end
        trailing_gt = ""
        if href.ends_with?("&gt;")
          trailing_gt = "&gt;"
          href = href[0...-4]
        end
        full = href.starts_with?("www.") ? "http://#{href}" : href
        outp << %(<a target="_blank" href=") << escape_once(full) << %(">)
        outp << escape_once(href) << %(</a>)
        outp << punctuation.reverse.join << trailing_gt
      end
      cursor = m_end
    end
    outp << text.byte_slice(cursor, text.bytesize - cursor)
    outp.to_s
  end

  private def self.auto_link_emails(text : String) : String
    text.gsub(AUTO_EMAIL_RE) do
      m = $~
      m_begin = text.char_index_to_byte_index(m.begin.not_nil!).not_nil!
      email = m[0].not_nil!
      m_end = m_begin + email.bytesize
      left = text.byte_slice(0, m_begin)
      right = text.byte_slice(m_end, text.bytesize - m_end)
      next m[0] if auto_linked?(left, right)
      %(<a target="_blank" href="mailto:) + escape_once(email) + %(">) +
        escape_once(email) + %(</a>)
    end
  end

  # URL already inside <a>…</a> or in the middle of a tag — do not link.
  private def self.auto_linked?(left : String, right : String) : Bool
    return true if left =~ /<[^>]+$/ && right =~ /\A[^>]*>/
    if idx = left.rindex(/<a[\s>]/)
      return !(left[idx..] =~ /<\/a>/i)
    end
    false
  end

  # ————— HTML entities (parsing attachment content attributes) —————

  def self.unescape_entities(text : String) : String
    text.gsub(/&(quot|amp|lt|gt|apos|nbsp|#39|#x27);/) do
      case $~[1]
      when "quot", "apos", "39", "x27" then "\""
      when "amp"                       then "&"
      when "lt"                        then "<"
      when "gt"                        then ">"
      when "nbsp"                      then " "
      else                                  $~[0]
      end
    end.gsub(/&#(\d+);/) { |m| ((m[/\d+/].to_i32?) || 63).chr.to_s }
  end

  ChatSound = Sound

  # Sound.find_by_name (app/models/sound.cr): the BUILTIN catalog.
  def self.sound_by_name(name : String) : Sound?
    Sound.find_by_name(name)
  end

  # Oracle Message#sound: a plain body of the form "/play <name>" with a
  # known name -> sound (content_type "sound").
  def self.message_sound(body : String?) : Sound?

    plain = body.to_s.gsub(/<[^>]*>/, " ").gsub("&nbsp;", " ").strip
    if (match = plain.match(/\A\/play (\w+)\z/))
      sound_by_name(match[1])
    end
  end

  # message_sound_presentation (MessagesHelper): div.sound with the 🔊
  # button and the sound's text/image.
  def self.sound_presentation(sound : Sound) : String
    String.build do |io|
      io << %(<div class="sound" data-action="messages:play-&gt;sound#play" data-controller="sound" )
      io << %(data-sound-url-value="#{asset("#{sound.name}.mp3")}">)
      io << %(<button class="btn btn--plain" data-action="sound#play">🔊</button>)
      if sound.image? && (iname = sound.image_name)
        io << %(<img class="align--middle" height="#{sound.image_height}" src="#{asset("sounds/#{iname}")}" width="#{sound.image_width}">)
      else
        io << sound.text.to_s
      end
      io << %(</div>)
    end
  end

  # Single message DOM — port of the oracle's _message.html.erb: id from
  # message.id (dom_id; client_message_id is only a data attribute),
  # turbo-frame edit_message_<id> around the body, presentation div
  # message_<id>_presentation, boosts (boosts/_boosts). An attachment
  # replaces the rich-text body (message_attachment_presentation).
  def self.message_dom(m : Message, room : Room, creator : User?,
                       attachment : Attachment? = nil,
                       boosts : Array(BoostEntry)? = nil,
                       base_url : String = "") : String
    mid = m.id.not_nil!
    cid = m.client_message_id.to_s
    created = m.created_at || Time.utc
    updated = m.updated_at || created
    permalink = route_path("room_at_message", room.id, mid)
    sound = attachment ? nil : message_sound(m.body.to_s)
    presentation_html = if attachment
      attachment_presentation(attachment)
    elsif sound
      sound_presentation(sound)
    else
      text_presentation(m.body.to_s)
    end
    # message--emoji: plain_text_body.all_emoji? — a sound ("/play …") is
    # not an emoji message; the class is derived from the body text, not
    # from the player markup.
    emoji = (attachment.nil? && sound.nil? && all_emoji?(presentation_html)) ? " message--emoji" : ""
    entries = boosts || boosts_for([mid])[mid]? || [] of BoostEntry

    # message_tag rescue -> _unrenderable.html.erb: the record's author is
    # deleted — a placeholder instead of the message (broken room).
    unless creator
      return %(<div class="message message--formatted message--failed center">\n) +
             %(<div class="message__body">\n) +
             %(<div class="message__body-content txt-align-center">\n) +
             %(    Failed to load message content\n) +
             %(  </div>\n</div>\n</div>\n)
    end
    creator = creator.not_nil!

    String.build do |io|
      io << %(<div id="message_#{mid}" class="message#{emoji}" data-controller="reply" )
      io << %(data-user-id="#{m.creator_id}" data-message-id="#{mid}" )
      io << %(data-message-timestamp="#{created.to_unix_ms}" data-message-updated-at="#{updated.to_unix_ms}" )
      io << %(data-sort-value="#{created.to_unix_ms}" data-messages-target="message" )
      io << %(data-search-results-target="message" data-refresh-room-target="message" )
      io << %(data-reply-composer-outlet="#composer" data-client-message-id=") << HTML.escape(cid) << %(">\n)
      io << %(<h2 class="message__day-separator"><time datetime="#{created.to_rfc3339}" data-local-time-target="date"></time></h2>\n)
      io << %(<figure class="avatar message__avatar">\n) << avatar_link(creator) << %(\n</figure>\n)
      io << %(<turbo-frame id="edit_message_#{mid}">\n<div class="message__body">\n<div class="message__body-content">\n)
      io << %(<div class="message__meta">\n<h3 class="message__heading">\n)
      io << %(<span class="message__author" title=")
      io << HTML.escape(user_title(creator.try(&.name), creator.try(&.bio)))
      io << %(">\n<strong data-reply-target="author">) << HTML.escape(creator.try(&.name).to_s) << %(</strong>\n</span>\n)
      io << %(<a target="_top" class="message__permalink" href="#{permalink}">)
      io << %(<time class="message__timestamp" datetime="#{created.to_rfc3339}" data-local-time-target="time"></time></a>\n)
      io << %(<span class="message__room">\n<a target="_top" data-reply-target="link" href="#{permalink}">)
      io << HTML.escape(room_display_name(room)) << %(</a>\n</span>\n)
      io << %(</h3>\n)
      io << message_actions(mid, room, permalink, attachment, base_url)
      io << %(</div>\n)
      io << presentation_dom(mid, presentation_html, lexxy_wrapper: attachment.nil? && sound.nil?)
      io << boosts_dom(mid, entries)
      io << %(</div>\n</div>\n</turbo-frame>\n</div>\n)
    end
  end

  # message--emoji: non-empty plain text with no letters or digits
  # (express allEmoji: !!plain && !/[\p{L}\p{N}]/u) — emoji/punctuation
  # only; the class enables the large font (messages.css .message--emoji).
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

  # ===== Message attachments (ActiveStorage, storage.js) =====

  # Message attachment: blob + filename (batch-loaded with a single IN).
  struct Attachment
    attr_accessor blob_id : Int64
    attr_accessor filename : String
    attr_accessor content_type : String
    attr_accessor key : String
    # width/height from the blob metadata (Rails ImageAnalyzer): Int64 as
    # in a JSON number, Float64 if the metadata stores a float; nil for
    # unanalyzed images (metadata "{}") and all non-images.
    attr_accessor width : Int64 | Float64 | Nil = nil
    attr_accessor height : Int64 | Float64 | Nil = nil

    def initialize(@blob_id, @filename, @content_type, @key)
    end

    def image? : Bool
      content_type.starts_with?("image/")
    end

    def video? : Bool
      content_type.starts_with?("video/")
    end
  end

  # Attachment blobs for a message list in one query.
  def self.attachments_for(message_ids : Array(Int64)) : Hash(Int64, Attachment)
    table = {} of Int64 => Attachment
    return table if message_ids.empty?
    placeholders = message_ids.map { "?" }.join(", ")
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT a.record_id, b.id, b.filename, b.content_type, b.key, b.metadata
        FROM active_storage_attachments a
        JOIN active_storage_blobs b ON b.id = a.blob_id
        WHERE a.record_type = 'Message' AND a.record_id IN (#{placeholders})),
      args: message_ids, as: {Int64, Int64, String, String, String, String?})
    rows.each do |(mid, bid, filename, ct, key, metadata)|
      attachment = Attachment.new(bid, filename, ct, key)
      if meta = metadata.presence
        json = JSON.parse(meta)
        attachment.width = json["width"]?.try(&.as_i64?) || json["width"]?.try(&.as_f?)
        attachment.height = json["height"]?.try(&.as_i64?) || json["height"]?.try(&.as_f?)
      end
      table[mid] = attachment
    end
    table
  end

  def self.storage_verifier
    # Oracle ActiveStorage.verifier: MessageVerifier SHA1, strict_b64 with
    # padding ('…fQ==--<sha40>'); urlsafe-nopad diverges from the Rails
    # blob_id signature here (avatar/sgid use other verifiers, untouched).
    CRails.application.message_verifier("ActiveStorage",
      digest: :sha1, url_safe: false)
  end

  # /rails/active_storage/blobs/redirect/<signed blob_id>/<filename>
  def self.blob_url(a : Attachment) : String
    token = storage_verifier.generate(a.blob_id, purpose: "blob_id")
    "/rails/active_storage/blobs/redirect/#{token}/#{URI.encode_path_segment(a.filename)}"
  end

  # /rails/active_storage/representations/redirect/<blob_id>/<variation>/<filename>
  # (transforms as in express: 1200x800; format is the file extension,
  # except the video poster where Rails always converts the frame to webp).
  def self.representation_url(a : Attachment, format : String? = nil) : String
    token = storage_verifier.generate(a.blob_id, purpose: "blob_id")
    ext = format || File.extname(a.filename).lchop('.')
    fmt = ext.empty? ? "png" : ext
    # Rails signs the transforms themselves (an object, not a string):
    # {"_rails":{"data":{"format":..,"resize_to_limit":[..]},"pur":"variation"}}
    variation = storage_verifier.generate(
      ActiveSupport::RawJSON.new(%({"format":"#{fmt}","resize_to_limit":[1200,800]})), purpose: "variation")
    "/rails/active_storage/representations/redirect/#{token}/#{variation}/#{URI.encode_path_segment(a.filename)}"
  end

  # ActiveStorage web_image? (Blob#web_image?): only these types go
  # through the variant preview in messages; bmp/tiff/svg and
  # non-images get render_link (file-chip), as in
  # Messages::AttachmentPresentation.
  WEB_IMAGE_TYPES = {"image/png", "image/jpeg", "image/jpg", "image/gif",
                     "image/webp"}

  # Oracle Messages::AttachmentPresentation: video — a video tag with a
  # poster (the frame is converted to webp), web image — lightbox + img,
  # everything else (txt, bmp, …) — a file-chip with icon, download and
  # share.
  def self.attachment_presentation(a : Attachment) : String
    url = blob_url(a)
    if a.video?
      content = %(<video src="#{url}" poster="#{representation_url(a, "webp")}" ) +
        %(controls="controls" preload="none" width="100%" height="100%" ) +
        %(class="message__attachment"></video>)
      inline_media_dimension_constraints(a, content)
    elsif WEB_IMAGE_TYPES.includes?(a.content_type)
      repr = representation_url(a)
      img = if (dims = preview_dimensions(a))
              %(<img width="#{number(dims[0])}" height="#{number(dims[1])}" ) +
                %(class="message__attachment" loading="lazy" src="#{repr}" />)
            else
              %(<img class="message__attachment" loading="lazy" src="#{repr}" />)
            end
      content = %(<a class="flex" data-lightbox-target="image" data-action="lightbox#open" ) +
        %(data-lightbox-url-value="#{url}?disposition=attachment" href="#{url}">) +
        img + %(</a>)
      inline_media_dimension_constraints(a, content)
    else
      download_url = "#{url}?disposition=attachment"
      name = HTML.escape(a.filename)
      %(<div class="flex-inline align-center gap-half">) +
        icon("common-file-text.svg", 22, "colorize--black") +
        %(<span>) + name + %(</span>) +
        %(<a class="btn message__action-btn hide-in-ios-pwa" href="#{download_url}" style="--width: auto;" target="_top">) +
        icon("download.svg") +
        %(<span class="for-screen-reader">Download ) + name + %(</span></a>) +
        %(<button class="btn message__action-btn" data-action="web-share#share" data-controller="web-share" ) +
        %(data-web-share-files-value="#{download_url}" hidden="" style="--width: auto;">) +
        icon("share.svg") +
        %(<span class="for-screen-reader">Share ) + name + %(</span></button></div>)
    end
  end

  # Message::THUMBNAIL_MAX_WIDTH/HEIGHT (oracle attachment.rb).
  THUMBNAIL_MAX_WIDTH  = 1200.0
  THUMBNAIL_MAX_HEIGHT = 800.0

  # preview_dimensions: original dimensions from metadata, scaled down to
  # the preview limit (scale is the min over both axes). Integers stay
  # integers (Rails divides Integer/2 with no fraction), scaled ones are
  # floats.
  private def self.preview_dimensions(a : Attachment) : {Int64 | Float64, Int64 | Float64}?
    w = a.width
    h = a.height
    return nil unless w && h
    wf = w.to_f
    hf = h.to_f
    return nil unless wf > 0 && hf > 0
    if wf <= THUMBNAIL_MAX_WIDTH && hf <= THUMBNAIL_MAX_HEIGHT
      {w, h}
    else
      scale = {THUMBNAIL_MAX_WIDTH / wf, THUMBNAIL_MAX_HEIGHT / hf}.min
      {wf * scale, hf * scale}
    end
  end

  # inline_media_dimension_constraints: the media block in a div wrapper
  # with half width and aspect-ratio; without metadata the wrapper has
  # no constraints (the image renders at natural size, so the wrapper is
  # required there too).
  private def self.inline_media_dimension_constraints(a : Attachment, content : String) : String
    if (dims = preview_dimensions(a))
      w, h = dims
      %(<div class="max-inline-size center flex overflow-clip" ) +
        %(style="width: #{half(w)}px; aspect-ratio: #{(w.to_f / h.to_f).to_s};">) +
        content + %(</div>)
    else
      %(<div class="max-inline-size center overflow-clip">) + content + %(</div>)
    end
  end

  # Number as in Ruby: Integer — to_s, Float — to_s (shortest
  # round-trip form with ".0" for wholes).
  private def self.number(v : Int64 | Float64) : String
    v.to_s
  end

  # width / 2 from inline_media_dimension_constraints: integer division
  # for Integer, float for Float.
  private def self.half(v : Int64 | Float64) : String
    case v
    in Int64   then (v // 2).to_s
    in Float64 then (v / 2).to_s
    end
  end

  # message_actions — port of _actions.html.erb: a summary menu with
  # quick-boosts (a form per reaction, submit into the
  # message_<id>_boosting turbo-frame), the custom boost button
  # (message__boost-btn -> new boost frame), Reply/Download+Share
  # (attachment), Copy link (absolute URL), Edit (edit_message_<id>).
  private def self.message_actions(mid : Int64, room : Room, permalink : String,
                                   attachment : Attachment?,
                                   base_url : String) : String
    url = base_url.empty? ? permalink : "#{base_url}#{permalink}"
    boost_path = route_path("message_boosts", mid)
    boost_frame = "boosting_message_#{mid}"

    String.build do |io|
      io << %(<div class="message__actions" data-controller="soft-keyboard">\n)
      io << %(<details class="position-relative" data-controller="popup" )
      io << %(data-popup-orientation-top-class="popup-orientation-top" )
      io << %(data-action="keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside">\n)
      io << %(<summary class="btn message__action-btn message__options-btn">\n)
      io << icon("menu-dots-horizontal.svg", 20, "colorize--black") << "\n"
      io << %(<span class="for-screen-reader">Message options</span>\n</summary>\n)
      io << %(<div class="message__actions-menu border shadow" data-popup-target="menu">\n)
      io << %(<div class="quick-boosts">\n)
      EmojiHelper::REACTIONS.each do |character, title|
        io << %(<form data-turbo-frame="#{boost_frame}" data-action="popup#close" )
        io << %(action="#{boost_path}" accept-charset="UTF-8" method="post">\n)
        io << %(<input type="hidden" name="boost[content]" id="boost_content" value=") << HTML.escape(character)
        io << %(">\n)
        io << %(<button name="button" type="submit" title=") << HTML.escape(title)
        io << %(" class="btn message__action-btn" data-emoji=") << HTML.escape(character) << %(">\n)
        io << %(<figure class="margin-none boost-character">) << character << %(</figure>\n)
        io << %(<span class="for-screen-reader">) << HTML.escape(title) << %(</span>\n)
        io << %(</button>\n</form>\n)
      end
      io << %(<a class="btn message__action-btn message__boost-btn" )
      io << %(data-turbo-frame="new_boost_message_#{mid}" data-action="soft-keyboard#open popup#close" )
      io << %(href="#{boost_path}/new">\n)
      io << icon("boost.svg", 20, "colorize--black") << "\n"
      io << %(<span class="for-screen-reader">New boost</span>\n</a>      </div>\n)
      io << %(<div class="flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid">\n)
      if attachment
        io << %(<a class="btn message__action-btn center full-width hide-in-ios-pwa" title="Download" )
        io << %(aria-label="Download" href="#{blob_url(attachment)}?disposition=attachment">\n)
        io << icon("download.svg", 20, "colorize--black") << "\n</a>\n"
        io << %(<button class="btn message__action-btn center full-width" data-controller="web-share" )
        io << %(data-action="web-share#share" data-web-share-files-value="#{blob_url(attachment)}" )
        io << %(data-web-share-title-value=") << HTML.escape(attachment.filename)
        io << %(" title="Share" aria-label="Share" hidden="">\n)
        io << icon("share.svg", 20, "colorize--black") << "\n</button>\n"
      else
        io << %(<button class="btn message__action-btn center full-width" data-action="reply#reply" )
        io << %(title="Reply" aria-label="Reply">\n)
        io << icon("reply.svg", 20, "colorize--black") << "\n</button>\n"
      end
      io << %(<button class="btn message__action-btn center full-width" title="Copy link" aria-label="Copy link" )
      io << %(data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" )
      io << %(data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value=")
      io << HTML.escape(url) << %(">\n)
      io << icon("link.svg", 20, "colorize--black") << "\n</button>\n"
      io << %(<a class="btn message__action-btn center full-width message__edit-btn" )
      io << %(data-turbo-frame="edit_message_#{mid}" title="Edit" aria-label="Edit" )
      io << %(href="#{route_path("edit_room_message", room.id, mid)}">\n)
      io << icon("pencil.svg", 20, "colorize--black") << "\n"
      io << %(</a>      </div>\n)
      io << %(</div>\n</details></div>\n)
    end
  end

  # _boosts.html.erb: turbo-frame boosting_message_<id> with the boosts
  # container (boosts_message_<id> — append stream target) and the lazy
  # new_boost_message_<id> frame ("Add a boost" button).
  def self.boosts_dom(mid : Int64, boosts : Array(BoostEntry)) : String
    String.build do |io|
      io << %(<turbo-frame id="boosting_message_#{mid}">\n)
      io << %(<div class="boosts flex flex-wrap align-center gap full-width" style="--column-gap: 0.4ch; --row-gap: 0" )
      io << %(data-controller="turbo-streaming" data-action="turbo:submit-start-&gt;turbo-streaming#unsubscribe">\n)
      io << %(<div class="flex-inline flex-wrap gap" id="boosts_message_#{mid}" data-turbo-streaming-target="container">\n)
      boosts.each { |b| io << boost_dom(mid, b) << "\n" }
      io << %(</div>\n)
      io << %(<turbo-frame id="new_boost_message_#{mid}">\n)
      io << %(<div class="flex-inline message__boost-inline" data-controller="soft-keyboard">\n)
      io << %(<a class="boost__action txt-small btn" data-action="soft-keyboard#open" href="#{route_path("new_message_boost", mid)}">\n)
      io << icon("boost.svg", 20) << "\n"
      io << %(<span class="for-screen-reader">Add a boost</span>\n)
      io << %(</a>      </div>\n)
      io << %(</turbo-frame>  </div>\n)
      io << %(</turbo-frame>\n)
    end
  end

  # _boost.html.erb: a boost with the booster's avatar, content (click
  # reveals delete) and the delete form (button_to _method=delete).
  def self.boost_dom(mid : Int64, b : BoostEntry) : String
    medium = all_emoji?(b.content) ? " txt-medium" : ""
    String.build do |io|
      io << %(<div id="boost_#{b.id}" class="boost boost-item flex-inline postion--relative max-width align-center fill-white gap" )
      io << %(data-controller="boost-delete" data-boost-delete-perform-class="boost--deleting" )
      io << %(data-boost-delete-reveal-class="expanded" data-boost-delete-booster-id-value="#{b.booster_id}">\n)
      io << %(<figure class="avatar boost__avatar flex-item-no-shrink">\n)
      io << %(<a title=") << HTML.escape(user_title(b.booster_name, b.booster_bio))
      io << %(" class="btn avatar" data-turbo-frame="_top" href="#{route_path("user", b.booster_id)}">)
      io << %(<img aria-label=")
      io << HTML.escape("#{b.booster_name} boosted #{b.content}")
      io << %(" src="#{fresh_user_avatar_path(b.booster_id, b.booster_updated_at)}" width="48" height="48"></a>\n)
      io << %(</figure>\n)
      io << %(<span role="button" class="txt-small#{medium}" )
      io << %(data-action="click-&gt;boost-delete#reveal keydown.enter-&gt;boost-delete#reveal:prevent" )
      io << %(data-boost-delete-target="content">) << HTML.escape(b.content) << %(</span>\n)
      io << %(<form class="button_to" action="/messages/#{mid}/boosts/#{b.id}" method="post">)
      io << %(<input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn btn--negative flex-item-justify-end boost__delete" )
      io << %(data-action="boost-delete#perform" data-boost-delete-target="button" type="submit">\n)
      io << icon("minus.svg", 20) << "\n"
      io << %(<span class="for-screen-reader">Delete this boost</span>\n)
      io << %(</button></form></div>\n)
      io << %(<span id="delete_boost_accessible_label" class="for-screen-reader">Press enter to delete this boost</span>)
    end
  end

  # Message list DOM with fragment cache — port of Rails `render
  # partial:, collection:, cached:` (rooms/show.html.erb + the oracle's
  # FragmentCache): hits are read from the cache in one pass before any
  # SQL; misses render fresh — their rooms (besides the passed one) and
  # authors are loaded with one IN query per entity — and written back
  # to the cache. Key = cache_key_with_version (id + updated_at),
  # freshness is the shared DB epoch (see FragmentCache).
  def self.messages_to(io : IO, messages : Array(Message), epoch : String,
                       room : Room? = nil, base_url : String = "") : Nil
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

    # Attachments and boosts with one IN query per entity (no N+1).
    attachments = attachments_for(messages.map(&.id.not_nil!))
    boosts = boosts_for(messages.map(&.id.not_nil!))

    messages.each do |m|
      if (html = hits[m.id.not_nil!]?)
        io << html
      elsif (r = rooms[m.room_id.not_nil!]?)
        html = message_dom(m, r, creators[m.creator_id.not_nil!]?,
          attachments[m.id.not_nil!]?, boosts[m.id.not_nil!]?, base_url)
        FragmentCache.set(FragmentCache.key(m), epoch, html)
        io << html
      end
    end
  end

  # String wrapper over messages_to (rooms#show: the result goes into
  # message_area).
  def self.messages_html(messages : Array(Message), epoch : String,
                         room : Room? = nil, base_url : String = "") : String
    String.build { |io| messages_to(io, messages, epoch, room, base_url) }
  end

  # The whole message-area (optimistic template + .messages + stream
  # source + composer) — room.eta + optimistic.eta. The optimistic
  # template is the messages controller's target "template".
  def self.message_area(room : Room, messages_html : String,
                        base_url : String = "") : String
    user = Current.user.not_nil!
    signed_name = HTML.escape(Turbo::Streams::StreamName.signed_stream_name([room, "messages"]))
    # messages_helper.rb:16 — messages_page_url_value: room_messages_url(room)
    # (absolute URL: the JS paginator does new URL(value) with no base).
    page_url = base_url.empty? ? route_path("room_messages", room.id) : "#{base_url}#{route_path("room_messages", room.id)}"
    String.build do |io|
      io << %(<div id="message-area" class="message-area" contents="true" data-controller="messages presence drop-target" )
      io << %(data-action="turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged" )
      io << %(data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" )
      io << %(data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" )
      io << %(data-messages-threaded-class="message--threaded" data-messages-page-url-value="#{HTML.escape(page_url)}">\n)
      # messages/_template.html.erb — div attributes on separate lines,
      # markup line by line (including the rails bug "</div
      # class=\"position-relative\">" — a closing tag with a class,
      # reproduced verbatim).
      io << %(<script type="text/template" data-messages-target="template">\n)
      io << %(<div class="message message--me $messageClasses$"\n)
      io << %(id="message_$clientMessageId$"\n)
      io << %(data-format-message-target="message"\n)
      io << %(data-pending-message="true"\n)
      io << %(data-client-message-id="$clientMessageId$"\n)
      io << %(data-user-id="#{user.id}"\n)
      io << %(data-message-timestamp="$messageTimestamp$"\n)
      io << %(data-messages-target="message">\n)
      io << %(<div class="message__day-separator"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="date"></time></div>\n)
      io << %(<figure class="avatar message__avatar">\n)
      io << %(<a title=") << HTML.escape(user_title(user.name, user.bio))
      io << %(" class="btn avatar" data-turbo-frame="_top" href="#{route_path("user", user.id)}">)
      io << %(<img aria-hidden="true" src="#{fresh_user_avatar_path(user.id.not_nil!, user.updated_at)}" width="48" height="48"/></a>\n)
      io << %(</figure>\n)
      io << %(<div class="message__body">\n)
      io << %(<div class="message__body-content">\n)
      io << %(<div class="message__meta">\n)
      io << %(<h3 class="message__heading">\n)
      io << %(<span class="message__author"><strong>) << HTML.escape(user.name.to_s) << %(</strong></span>\n)
      io << %(<span class="message__permalink"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="time"></time></span>\n)
      io << %(</h3>\n)
      io << %(<div class="message__actions">\n)
      io << %(<div class="position-relative">\n)
      io << %(<span class="btn message__action-btn message__options-btn">\n)
      io << %(<img aria-hidden="true" class="colorize--black" src="#{asset("menu-dots-horizontal.svg")}"/>\n)
      io << %(<span class="for-screen-reader">Message options</span>\n)
      io << %(</span>\n)
      io << %(</div class="position-relative">\n)
      io << %(</div>\n)
      io << %(</div>\n)
      io << %($body$\n)
      io << %(</div>\n)
      io << %(</div>\n)
      io << %(</div>\n)
      io << %(</script>\n)
      # messages_helper.rb:28 — refresh_room_loaded_at_value: the room's
      # updated_at epoch; id is the room's dom_id (rooms_open_<id>), URL
      # is absolute.
      refresh_url = base_url.empty? ? "/rooms/#{room.id}/refresh" : "#{base_url}/rooms/#{room.id}/refresh"
      io << %(<div id="messages_#{room.dom_id}" class="messages" data-controller="maintain-scroll refresh-room" )
      io << %(data-action="turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online" )
      io << %(data-messages-target="messages" data-refresh-room-loaded-at-value="#{(room.updated_at || Time.utc).to_unix_ms}" )
      io << %(data-refresh-room-url-value="#{HTML.escape(refresh_url)}">\n)
      io << messages_html
      io << %(</div>\n)
      io << %(<turbo-cable-stream-source channel="RoomMessagesChannel" signed-stream-name="#{signed_name}"></turbo-cable-stream-source>\n)
      io << %(<button class="message-area__return-to-latest btn" data-action="messages#returnToLatest" data-messages-target="latest" hidden="hidden">)
      io << icon("arrow-down.svg", 20)
      io << %(<span class="for-screen-reader">Jump to newest message</span></button>\n)
      io << %(</div>\n)
    end
  end
end
