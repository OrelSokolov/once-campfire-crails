# ChatERB: ERB rendering context for the app/views/** HTML templates
# (markup lives in templates compiled at build time via compile_template,
# like the jbuilder partials); helpers delegate to ChatLayout.
class ChatERB
  include ERB::Rendering
  # The sidebar/composer/_direct templates render both in controller
  # context and here, so the named *_path helpers must work in both;
  # route_set is assigned by railties at boot.
  include CRails::Routes::UrlHelpers
  # Block capture form of turbo_frame_tag (turbo_cr shard) for
  # rooms/involvements/** (bell, show).
  include Turbo::FramesHelper

  def initialize(@room : Room? = nil, @footer : String = "", @sidebar : String = "",
                 @origin : String = "", @involvement : String = "mentions",
                 @ua : String = "",
                 @user : User? = nil,
                 @directs : Array(SidebarDirect) = [] of SidebarDirect,
                 @shared : Array(SidebarShared) = [] of SidebarShared,
                 @placeholders : Array(User) = [] of User,
                 @rooms_stream : String = "", @user_rooms_stream : String = "")
  end

  # rooms/show/_composer.html.erb, rooms/involvements/**
  def room : Room
    @room.not_nil!
  end

  # layouts/_body_close.html.erb (SafeString: raw HTML for <%= %>)
  def footer : ERB::SafeString
    ERB::SafeString.new(@footer)
  end

  # layouts/_body_close.html.erb — the oracle's content_for :sidebar string
  # (SafeString). Named sidebar_html, not sidebar: compile_template
  # "sidebar" below defines the sidebar template render method and would
  # shadow this accessor.
  def sidebar_html : ERB::SafeString
    ERB::SafeString.new(@sidebar)
  end

  # asset("arrow-up.svg") → "/assets/arrow-up-f96b3895.svg" (ChatLayout).
  def asset(name : String) : String
    ChatLayout.asset(name)
  end

  # Layout lightbox dialog (layouts/_lightbox).
  def lightbox : ERB::SafeString
    ERB::SafeString.new(ChatLayout.lightbox_dialog)
  end

  # ————— rooms/involvements (bell + pwa dialogs + show) —————

  # User-agent classification for the pwa instructions (ApplicationPlatform).
  def platform : ApplicationPlatform
    ApplicationPlatform.new(@ua)
  end

  # Oracle root_url (the instructions print an absolute origin).
  def root_url : String
    @origin.empty? ? "/" : "#{@origin}/"
  end

  # rich_text_area (ActionText): absolute route URLs — rails_direct_uploads_url
  # and the blob-redirect template.
  def direct_uploads_url : String
    @origin.empty? ? "/rails/active_storage/direct_uploads" : "#{@origin}/rails/active_storage/direct_uploads"
  end

  def blob_url_template : String
    base = @origin.empty? ? "" : @origin
    "#{base}/rails/active_storage/blobs/redirect/:signed_id/:filename"
  end

  def involvement : String
    @involvement
  end

  # direct: everything -> nothing; others: mentions -> everything ->
  # nothing -> invisible (RoomsHelper#next_involvement_for).
  def next_involvement : String
    choices = room.direct? ? %w[everything nothing] : %w[mentions everything nothing invisible]
    idx = choices.index(involvement) || -1
    choices[(idx + 1) % choices.size]
  end

  def human_involvement : String
    ChatLayout::INVOLVEMENT_LABELS[involvement]? || involvement
  end

  # "Ping" for direct rooms, "room" otherwise (bell SR text).
  def noun : String
    room.direct? ? "Ping" : "room"
  end

  # Oracle dom_id: STI route_key (Rooms::Open -> rooms_open). type can be
  # full ('Rooms::Open', seed) or short ('Open', created via the port) —
  # normalized to the last segment, downcased.
  def dom_id(prefix : String) : String
    sti = room.type.to_s.split("::").last?.to_s.downcase
    "#{prefix}_rooms_#{sti}_#{room.id}"
  end

  # ————— users/sidebars/show (sidebar) —————

  class SidebarDirect
    attr_accessor room_id : Int64, epoch_ms : Int64, unread : Bool, members : Array(User)

    def initialize(@room_id, @epoch_ms, @unread, @members)
    end
  end

  class SidebarShared
    attr_accessor room : Room, unread : Bool

    def initialize(@room, @unread)
    end
  end

  def directs : Array(SidebarDirect)
    @directs
  end

  def shared : Array(SidebarShared)
    @shared
  end

  def placeholders : Array(User)
    @placeholders
  end

  def user : User
    @user.not_nil!
  end

  def rooms_stream : String
    @rooms_stream
  end

  def user_rooms_stream : String
    @user_rooms_stream
  end

  # fresh_user_avatar_path (UsersHelper) for the sidebar avatars.
  def avatar_path(u : User) : String
    ChatLayout.fresh_user_avatar_path(u.id.not_nil!, u.updated_at)
  end

  # Direct room label: one member — the first word of the name; several —
  # initials (first letter of up to 3 words each) joined to_sentence-style.
  def direct_label(d : SidebarDirect) : String
    direct_label(d.members)
  end

  def direct_label(members : Array(User)) : String
    if members.size > 1
      parts = members.map do |m|
        m.name.to_s.split(" ")[0, 3].map { |w| (w[0]? || "").upcase }.join
      end
      case parts.size
      when 2 then parts.join("+")
      else        "#{parts[0..-2].join(", ")}, and #{parts[-1]}"
      end
    else
      members.first.name.to_s.split(" ")[0]? || ""
    end
  end

  # ————— users/sidebars/rooms/_direct (turbo-stream prepend create) —————
  # The partial is rendered from a broadcast (directs#create), not from
  # the sidebar template (which batch-loads members), so member data is
  # computed from the membership, as in the oracle.

  # room.users.without(membership.user).presence || [membership.user]
  def direct_members(membership : Membership) : Array(User)
    members = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)),
      membership.room_id.not_nil!).to_a
      .reject { |u| u.id == membership.user_id }
    members.empty? ? [membership.user.not_nil!] : members
  end

  # Oracle Membership#unread?: unread_at.present?
  def unread?(membership : Membership) : Bool
    !membership.unread_at.nil?
  end

  # Sidebar data-sorted-list-number: room updated_at epoch in ms.
  def epoch_ms(room : Room) : Int64
    t = room.updated_at.as(Time)
    (t.to_unix * 1000) + (t.nanosecond // 1_000_000)
  end

  # Oracle dom_id(room, :list): STI route_key (Rooms::Open -> rooms_open),
  # normalized to rooms_<sti> for both full and short type values.
  def route_key(room : Room) : String
    "rooms_#{room.type.to_s.split("::").last?.to_s.downcase}"
  end

  def new_room_allowed? : Bool
    # Current.user.administrator? || !restrict_room_creation_to_administrators?
    user.role == 1 || !Account.take.try(&.restrict_room_creation_to_administrators?)
  end

  # _show.html.erb (not show.html.erb): compiled only here in the ChatERB
  # context with locals; the unprefixed name would also be picked up by
  # the implicit template scan of Users::SidebarsController#show, which
  # has no locals (the controller renders the sidebar itself via this
  # template and PageCache).
  compile_template "sidebar", "app/views/users/sidebars/_show.html.erb", dedent: true

  compile_template "composer", "app/views/rooms/show/_composer.html.erb"
  compile_template "body_close", "app/views/layouts/_body_close.html.erb", dedent: true
  compile_template "bell", "app/views/rooms/involvements/_bell.html.erb"
  compile_template "involvement_show", "app/views/rooms/involvements/_show.html.erb", dedent: true
  compile_template "incompatible_browser", "app/views/sessions/incompatible_browser.html.erb"

  # Nested partials go through render(): compile_template methods switch
  # the shared @__erb_buf, so a nested call would clobber the parent's
  # buffer; partials swap it out and restore it.
  compile_partials({
    "users/sidebars/rooms/direct" => {path: "app/views/users/sidebars/rooms/_direct.html.erb", locals: {"membership" => Membership}},
    "browser_settings"     => {path: "app/views/pwa/_browser_settings.html.erb", locals: {} of String => Nil},
    "system_settings"      => {path: "app/views/pwa/_system_settings.html.erb", locals: {} of String => Nil},
    "install_instructions" => {path: "app/views/pwa/_install_instructions.html.erb", locals: {} of String => Nil},
  })
end
