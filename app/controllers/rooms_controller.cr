class RoomsController < ApplicationController
  include RoomScoped
  include UserIdsParams
  include RoomsHelper

  before_action :set_room, only: [:show, :destroy]
  before_action :ensure_can_administer, only: [:destroy]

  @room : Room?
  @kind : String = ""
  @user : User?
  # Getter for RoomsHelper#page_open (the module can't see @user).
  attr_reader :user
  @selected : Set(Int64) = Set(Int64).new
  @is_open : Bool = false
  @can_administer : Bool = false
  @users : Array(User) = [] of User
  @divider : Int32 = 0
  @direct : Bool = false
  @direct_title : String = ""
  @direct_members : Array(User) = [] of User

  # Room form partial; locals become the typed arguments of the compiled method.
  compile_partials({
    "rooms/_form" => {path: "app/views/rooms/_form.html.erb",
                      locals: {"room" => Room?, "kind" => String,
                               "user" => User, "selected" => Set(Int64),
                               "is_open" => Bool, "can_administer" => Bool,
                               "users" => Array(User), "divider" => Int32}},
  }, dedent: true)

  def show
    user = current_user.not_nil!
    page = cache_page("rooms#show", user.id) { room_page(@room.not_nil!, user, find_messages) }
    # last_room cookie on every response, but after the cache decision
    # (a Set-Cookie before cache_page would prevent storing the page).
    remember_last_room_visited(@room.not_nil!)
    send_page(page)
  end

  # GET /rooms/:id/refresh and /rooms/:id/involvement live in Rooms::RefreshesController
  # and Rooms::InvolvementsController (app/controllers/rooms/).

  def destroy
    room = @room.not_nil!
    rid = room.id.not_nil!
    room.destroy_later
    broadcast_remove_room(rid, room.type.to_s)
    redirect_to root_url
  end

  # Target is the sidebar's dom_id(room, :list).
  private def broadcast_remove_room(rid : Int64, room_type : String) : Nil
    kind = room_type.split("::").last?.to_s.downcase
    broadcast_remove_to(["rooms"], target: "list_rooms_#{kind}_#{rid}")
  end

  # Subclasses narrow this to the room types they're allowed to act on, so that one
  # room namespace can't be used to reach another's rooms.
  def room_scope
    Current.user.not_nil!.rooms
  end

  def ensure_can_administer
    head :forbidden unless Current.user.not_nil!.can_administer?(@room)
  end

  # With restrict_room_creation_to_administrators, creating rooms (opens/closeds) is
  # admin-only; directs are unrestricted (called from the Rooms::Opens/Closeds subclasses).
  def ensure_permission_to_create_rooms : Nil
    account = Account.take
    if account.try(&.restrict_room_creation_to_administrators?) &&
       !Current.user.not_nil!.administrator?
      head(:forbidden)
    end
  end

  def room_params
    params.require(:room).permit(:name)
  end

  # Contract: last 40 by created_at DESC, output ASC. Deep-link /rooms/:id/@:message_id →
  # page_around (pagination.rb): 40 before + the anchor + 40 after. Comparison goes through
  # an id subquery: the sqlite3 shard serializes literal Time binds with milliseconds, which
  # made the anchor appear both in before and in [anchor], duplicating it in the output.
  def find_messages : Array(Message)
    room = @room.not_nil!
    if (mid = params["message_id"]?.try(&.to_s).try(&.to_i64?)) &&
       (anchor = Message.where("room_id = ? AND id = ?",
         room.id.not_nil!, mid).first?)
      before = Message.where(
        "room_id = ? AND created_at < (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, mid)
        .order("created_at DESC").limit(40).to_a.reverse
      after = Message.where(
        "room_id = ? AND created_at > (SELECT created_at FROM messages WHERE id = ?)",
        room.id.not_nil!, mid)
        .order("created_at ASC").limit(40).to_a
      before + [anchor] + after
    else
      Message.where("room_id = ?", room.id.not_nil!)
        .order("created_at DESC").limit(40).to_a.reverse
    end
  end

  # TrackedRoomVisit: cookies.permanent.
  def remember_last_room_visited(room : Room) : Nil
    cookies.permanent["last_room"] = room.id.not_nil!.to_s
  end

  # Shared create for Rooms::Opens/Closeds: a room of class klass + memberships for
  # member_ids, broadcast the sidebar link, redirect to /rooms/<id>.
  def create_room(klass : Rooms::Open.class | Rooms::Closed.class,
                  member_ids : Array(Int64),
                  user : User) : Nil
    Campfire::ResponseCache.invalidate!
    room = klass.new(
      name: room_params["name"]?.to_s,
      creator_id: user.id.not_nil!,
      created_at: Time.utc, updated_at: Time.utc)
    room.save!
    # Rooms::Open already granted every active user in after_save_commit
    # (see rooms/open.cr); grant the remaining selected members —
    # memberships.grant_to insert_all, duplicates skipped, default involvement.
    now = Time.utc
    member_ids.each do |uid|
      ActiveRecord::Base.connection.exec(
        "insert into memberships (room_id, user_id, involvement, connections, created_at, updated_at) " \
        "values (?, ?, 'mentions', 0, ?, ?) on conflict do nothing",
        room.id.not_nil!, uid, now, now)
    end

    broadcast_sidebar_link(room)
    redirect_to room_url(room.id)
  end

  # Shared update for Rooms::Opens/Closeds: rename + sync memberships by user_ids[]
  # (opens don't rebuild membership), broadcast prepend with the same id so Turbo
  # deduplicates and moves the link.
  def update_room : Nil
    Campfire::ResponseCache.invalidate!
    room = @room.not_nil!
    if name = room_params["name"]?
      room.name = name.to_s
    end
    room.updated_at = Time.utc
    room.save!

    unless room.type.to_s.ends_with?("Open")
      wanted = selected_user_ids.unshift(room.creator_id.not_nil!).uniq!.to_set
      existing = Membership.where("room_id = ?", room.id.not_nil!)
      existing.each do |m|
        unless wanted.includes?(m.user_id.not_nil!)
          # destroy (not delete): Membership#after_destroy_commit resets the
          # revoked user's remote connections — memberships.revoke_from.
          m.destroy
        end
      end
      have = existing.map(&.user_id.not_nil!).to_set
      now = Time.utc
      wanted.each do |uid|
        next if have.includes?(uid)
        ActiveRecord::Base.connection.exec(
          "insert into memberships (room_id, user_id, involvement, connections, created_at, updated_at) " \
          "values (?, ?, 'mentions', 0, ?, ?) on conflict do nothing",
          room.id.not_nil!, uid, now, now)
      end
    end

    broadcast_sidebar_link(room)
    redirect_to room_url(room.id)
  end

  # Data for _form.html.erb: selected members, admin/open flags, users (selected first,
  # then by name), divider position.
  def prepare_room_form(room : Room?, kind : String, user : User) : Nil
    @room = room
    @kind = kind
    @user = user
    selected = if r = room
      Membership.where("room_id = ?", r.id.not_nil!)
        .map(&.user_id.not_nil!).to_set
    else
      Set(Int64).new.tap { |s| s << user.id.not_nil! }
    end
    @selected = selected
    @is_open = kind == "opens"
    @can_administer = room.nil? || user.role == 1 || room.creator_id == user.id
    @users = User.active.to_a.sort_by(&.name.to_s.downcase)
    if @is_open
      # opens form: User.active.ordered is just LOWER(name), no selected/others split.
      @divider = 0
    else
      @users.sort! { |a, b|
        (selected.includes?(b.id.not_nil!) ? 1 : 0) <=>
        (selected.includes?(a.id.not_nil!) ? 1 : 0)
      }
      @divider = selected.size
    end
  end

  # turbo-stream prepend of the room link into #shared_rooms: the id matches the
  # reference's DOM("list"), so Turbo deduplicates on rename.
  def broadcast_sidebar_link(room : Room) : Nil
    kind = room.type.to_s.split("::").last?.try(&.downcase)
    link = String.build do |io|
      io << %(<a class="align-center gap room btn txt-nowrap" data-sorted-list-target="item" )
      io << %(data-room-id=") << room.id.not_nil!.to_s
      io << %(" data-sorted-list-name=") << HTML.escape(room.name.to_s)
      io << %(" id="list_rooms_) << kind << "_" << room.id.not_nil!.to_s
      io << %(" style="--column-gap: 0.5em" href="/rooms/) << room.id.not_nil!.to_s << %(">)
      io << %(<span class="overflow-ellipsis">) << HTML.escape(room.name.to_s) << %(</span></a>)
    end
    broadcast_prepend_to(["rooms"], target: "shared_rooms", html: link)
  end
end
