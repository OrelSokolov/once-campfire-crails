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

  # fresh_account_logo (oracle direct helper, config/routes.cr): the
  # helpers read Current.account; compile-time builders pass the account
  # they already hold (one row — same value, no extra query).
  def self.fresh_account_logo_path(account : Account?, size : String? = nil) : String
    route_for(:account_logo, v: account.try(&.updated_at).try(&.to_fs(:number)), size: size)
  end

  # rooms/show/_nav.html.erb (content_for :nav of the chat page): current
  # room chip (btn--reversed room--current), settings button with the
  # menu-dots-horizontal icon, involvement bell. Direct rooms (name NULL):
  # room_display_name — the other members' names. The <nav> wrapper and
  # everything around it is layouts/application.html.erb.
  def self.chat_nav(room : Room, ua : String = "", origin : String = "") : String
    viewer = Current.user
    String.build do |io|
      noun = "room"
      io << %(<span class="btn btn--reversed btn--faux room--current">\n)
      io << %(<h1 class="room__contents txt-medium overflow-ellipsis">\n)
      if room.name.nil?
        noun = "Ping"
        members = User.where(
          %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)), room.id.not_nil!)
          .order("id").to_a
          .reject { |m| viewer && m.id == viewer.id }
        names = members.map(&.name.to_s)
        io << %(<span class="for-screen-reader">Ping with</span>\n)
        io << HTML.escape(sentence(names)) << "\n"
      else
        io << HTML.escape(room.name.to_s) << "\n"
      end
      io << %(</h1>\n</span>\n)
      io << %(<a class="btn" data-room-id="#{room.id}" href="#{room_edit_path(room)}" )
      io << %(style="view-transition-name: edit-room-#{room.id}">\n)
      io << %(<img aria-hidden="true" height="20" src="#{asset("menu-dots-horizontal.svg")}" width="20">\n)
      io << %(<span class="for-screen-reader">Settings for this #{noun}</span>\n</a>\n)
      io << involvement_bell(room, viewer, ua: ua, origin: origin)
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

  # ===== Shared asset/icon helpers =====

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

  # rooms/show/_invitation.html.erb + accounts/_invite.html.erb — the
  # "Welcome to Campfire" block above the original room's messages
  # (Room.original, while it has no more than PAGE_SIZE messages):
  # account logo, invite_message translation, and the invite section
  # (accounts/_invite partial, rendered by RoomsHelper#invitation_html).
  def self.system_welcome(origin : String, invite_html : String) : String
    user = Current.user
    return "" unless user
    account = Account.take
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
      io << invite_html
      io << %(</div>\n</div>\n</div>\n)
    end
  end

  # Oracle User#title: "name – bio" (bio may be NULL).
  def self.user_title(name : String?, bio : String?) : String
    bio.to_s.empty? ? name.to_s : "#{name} – #{bio}"
  end

  # fresh_user_avatar_path (oracle avatars_helper): public path
  # /users/<signed_id purpose=user/avatar>/avatar?v=<updated_at YYYYMMDDHHMMSS>.
  # The token is deterministic (shared secret) and byte-identical to the
  # Rails token. Snapshot flavor for the hot path (boost entries render
  # without instantiating AR records); object calls go through the
  # `direct :fresh_user_avatar` helper (config/routes.cr).
  def self.fresh_user_avatar_path(user_id : Int64, updated_at : Time?) : String
    token = CRails.application
      .message_verifier("active_record/signed_id", url_safe: true)
      .generate(user_id, purpose: "user/avatar")
    route_for(:user_avatar, token, v: (updated_at || Time.utc).to_fs(:number))
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
  # Carries message_id so the _boost partial can build the delete form
  # without the Boost record (snapshot, not an AR object).
  struct BoostEntry
    attr_accessor id : Int64
    attr_accessor message_id : Int64
    attr_accessor content : String
    attr_accessor booster_id : Int64
    attr_accessor booster_name : String
    attr_accessor booster_bio : String?
    attr_accessor booster_updated_at : Time?

    def initialize(@id, @message_id, @content, @booster_id, @booster_name,
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
      list << BoostEntry.new(bid, mid, content, booster_id, name, bio, updated)
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

  # Single message DOM — rendered through the messages/_message ERB
  # partial (MessagesERB context, oracle app/views/messages/_message +
  # _actions + _presentation + boosts/_boosts): id from message.id
  # (dom_id; client_message_id is only a data attribute), turbo-frame
  # edit_message_<id> around the body, presentation div
  # message_<id>_presentation, boosts (boosts/_boosts). An attachment
  # replaces the rich-text body (message_attachment_presentation).
  def self.message_dom(m : Message, room : Room, creator : User?,
                       attachment : Attachment? = nil,
                       boosts : Array(BoostEntry)? = nil,
                       base_url : String = "") : String
    mid = m.id.not_nil!
    entries = boosts || boosts_for([mid])[mid]? || [] of BoostEntry
    MessagesERB.new(m, room, creator, attachment, entries, base_url).render_message
  end

  # message--emoji: non-empty plain text with no letters or digits
  # (express allEmoji: !!plain && !/[\p{L}\p{N}]/u) — emoji/punctuation
  # only; the class enables the large font (messages.css .message--emoji).
  def self.all_emoji?(body_html : String?) : Bool
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
  # Rendered through the messages/_actions ERB partial (MessagesERB).

  # _boosts.html.erb: turbo-frame boosting_message_<id> with the boosts
  # container (boosts_message_<id> — append stream target) and the lazy
  # new_boost_message_<id> frame ("Add a boost" button). Rendered through
  # the messages/boosts/_boosts ERB partial (BoostsERB context) — the
  # collection _boost partial via render partial: collection:, as the
  # oracle does off message.boosts.
  def self.boosts_dom(mid : Int64, boosts : Array(BoostEntry)) : String
    # Trailing "\n": the caller template's literal newline after the
    # render call (_message.html.erb) — the partial's own final newline
    # is eaten by the Erubi trim of `<% end %>`.
    BoostsERB.new.render(partial: "messages/boosts/boosts",
      locals: {"message_id" => mid, "boosts" => boosts}).to_s + "\n"
  end

  # _boost.html.erb (single-entry entry point for the boosts broadcast
  # in boosts/by_bots controllers; callers append "\n" — the partial's
  # own trailing newline when rendered through a collection).
  def self.boost_dom(mid : Int64, b : BoostEntry) : String
    BoostsERB.new.render(partial: "messages/boosts/boost",
      locals: {"boost" => b}).to_s
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
      io << %(data-messages-target="messages" data-refresh-room-loaded-at-value="#{(room.updated_at || Time.utc).to_fs(:epoch)}" )
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
