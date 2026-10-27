# ChatERB: ERB rendering context for the app/views/** HTML templates
# (markup lives in templates compiled at build time via compile_template,
# like the jbuilder partials); helpers delegate to ChatLayout.
# The sidebar direct-row partial (users/sidebars/rooms/_direct) renders
# both from a Membership (directs#create broadcast) and from a
# SidebarDirect snapshot (the sidebar collection item) — the typed local
# is the union (a type alias: compile_partials resolves a Path, not a
# `A | B` call AST).
alias SidebarDirectLocal = Membership | ChatERB::SidebarDirect

class ChatERB
  # Full ActionView surface (like the controllers' render context):
  # form_with/composer_form_tag needs FormBuilder, whose @view is typed
  # ActionView::Helpers — individual module includes don't satisfy it.
  include ActionView::Helpers
  # The sidebar/composer/_direct templates render both in controller
  # context and here, so the named *_path helpers must work in both;
  # route_set is assigned by railties at boot.
  include CRails::Routes::UrlHelpers
  # Block capture form of turbo_frame_tag (turbo_cr shard) for
  # rooms/involvements/** (bell, show).
  include Turbo::FramesHelper
  # Oracle app/helpers/rich_text_helper.rb + drop_target_helper.rb —
  # editor surface shared with the message edit form.
  include RichTextHelper
  include DropTargetHelper

  def initialize(@room : Room? = nil,
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

  # asset("arrow-up.svg") → "/assets/arrow-up-f96b3895.svg" (ChatLayout).
  def asset(name : String) : String
    ChatLayout.asset(name)
  end

  # Propshaft-style manifest resolution (same override as ApplicationHelper).
  include ActionView::Helpers::TagHelper
  # button_to (UrlHelper) for rooms/involvements/** templates.
  include ActionView::Helpers::UrlHelper

  def image_tag(source : String, **opts) : ERB::SafeString
    ::ActionView::Helpers::AssetTagHelper.image_tag(
      ChatLayout.asset(source), __av_opts_to_h(opts))
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

  # Request origin (rich_text_area data-URL defaults, see RichTextHelper).
  def origin : String
    @origin
  end

  # Oracle RoomsHelper#composer_form_tag — rendered only through ChatERB
  # (the composer template lives here).
  def composer_form_tag(room : Room, &) : String
    form_with model: Message.new, url: room_messages_path(room.id),
      id: "composer", class: "margin-block flex-item-grow contain", data: composer_data_options(room) do |form|
      yield form
    end
  end

  private def composer_data_options(room : Room)
    {
      controller:                "composer drop-target",
      action:                    composer_data_actions,
      composer_messages_outlet:  "#message-area",
      composer_toolbar_class:    "composer--rich-text",
      composer_room_id_value:    room.id,
    }
  end

  private def composer_data_actions : String
    drag_and_drop_actions = "drop-target:drop@window->composer#dropFiles"

    attachment_actions =
      "lexxy:file-accept->composer#preventAttachment refresh-room:online@window->composer#online"

    remaining_actions =
      "typing-notifications#stop paste->composer#pasteFiles turbo:submit-end->composer#submitEnd refresh-room:offline@window->composer#offline"

    [drop_target_actions, drag_and_drop_actions, attachment_actions, remaining_actions].join(" ")
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

  # View model of a sidebar direct-room row: the oracle renders the
  # users/sidebars/rooms/_direct partial collection off Membership
  # records (associations preloaded by the controller); the port
  # batch-loads rooms/members/unread in the helper, so the snapshot
  # travels as the collection item (BoostEntry precedent). The partial
  # and its helpers dispatch on the local's type — the broadcast path
  # (directs#create) still renders the same partial off a Membership.
  class SidebarDirect
    attr_accessor room : Room
    attr_accessor unread : Bool
    attr_accessor members : Array(User)

    def initialize(@room, @unread, @members)
    end

    def room_id : Int64
      @room.id.not_nil!
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
    ChatLayout.fresh_user_avatar_path(u.id!, u.updated_at)
  end

  # Direct room label: one member — the first word of the name; several —
  # initials (first letter of up to 3 words each) joined to_sentence-style.
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
      membership.room_id!).to_a
      .reject { |u| u.id == membership.user_id }
    members.empty? ? [membership.user.not_nil!] : members
  end

  # Sidebar collection item: members are batch-preloaded (no SQL here).
  def direct_members(entry : SidebarDirect) : Array(User)
    entry.members
  end

  # Oracle Membership#unread?: unread_at.present?
  def unread?(membership : Membership) : Bool
    !membership.unread_at.nil?
  end

  def unread?(entry : SidebarDirect) : Bool
    entry.unread
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
    user.administrator? || !Account.take.try(&.restrict_room_creation_to_administrators?)
  end

  # _show.html.erb (not show.html.erb): compiled only here in the ChatERB
  # context with locals; the unprefixed name would also be picked up by
  # the implicit template scan of Users::SidebarsController#show, which
  # has no locals (the controller renders the sidebar itself via this
  # template and PageCache).
  compile_template "sidebar", "app/views/users/sidebars/_show.html.erb", dedent: true

  compile_template "composer", "app/views/rooms/show/_composer.html.erb"
  compile_template "bell", "app/views/rooms/involvements/_bell.html.erb"
  compile_template "involvement_show", "app/views/rooms/involvements/_show.html.erb", dedent: true
  compile_template "incompatible_browser", "app/views/sessions/incompatible_browser.html.erb"

  # Nested partials go through render(): compile_template methods switch
  # the shared @__erb_buf, so a nested call would clobber the parent's
  # buffer; partials swap it out and restore it.
  compile_partials({
    # The direct row renders both from a Membership (directs#create
    # broadcast) and from a SidebarDirect snapshot (sidebar collection).
    "users/sidebars/rooms/direct" => {path: "app/views/users/sidebars/rooms/_direct.html.erb",
                                      locals: {"membership" => SidebarDirectLocal}},
    "users/sidebars/rooms/shared" => {path: "app/views/users/sidebars/rooms/_shared.html.erb",
                                      locals: {"room" => Room, "unread" => Bool}},
    "users/sidebars/rooms/direct_placeholder" => {path: "app/views/users/sidebars/rooms/_direct_placeholder.html.erb",
                                                  locals: {"user" => User}},
    "browser_settings"     => {path: "app/views/pwa/_browser_settings.html.erb", locals: {} of String => Nil},
    "system_settings"      => {path: "app/views/pwa/_system_settings.html.erb", locals: {} of String => Nil},
    "install_instructions" => {path: "app/views/pwa/_install_instructions.html.erb", locals: {} of String => Nil},
  })

  # Oracle collection render passes cached: true (fragment cache); the
  # sidebar renders through the whole-page ResponseCache, so the flag is
  # accepted for the 1:1 call shape and is a no-op here.
  #
  # NOTE: must stay AFTER compile_partials — a hand-written def that
  # precedes the macro-generated `render` pair is shadowed by it (the
  # overloads never merge); previous_def delegates to the generated
  # collection render without re-entering this overload (a plain
  # render(...) call would re-match cached:'s default).
  def render(partial : String, *, collection : Array, as_local : String? = nil,
             locals : Hash? = nil, spacer_template : String? = nil,
             cached : Bool = false) : ERB::SafeString
    previous_def(partial, collection: collection, as_local: as_local,
      locals: locals, spacer_template: spacer_template)
  end
end
