# Users::SidebarHelper: renders the /users/me/sidebar page — ChatERB view
# models, turbo-frame wrapper and layout shell.
module Users::SidebarHelper
  include ActionController::Helper

  # Oracle users/sidebar_helper.rb sidebar_turbo_frame_tag: the user_sidebar
  # frame — src on the first render (rooms/show, welcome/show), block
  # content on the frame reload (users/sidebars/show).
  SIDEBAR_FRAME_DATA = {
    "turbo_permanent"         => true,
    "controller"              => "rooms-list read-rooms turbo-frame",
    "rooms_list_unread_class" => "unread",
    "action"                  => "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload",
  }

  def sidebar_turbo_frame_tag(src : String? = nil) : ERB::SafeString
    turbo_frame_tag "user_sidebar", src: src, target: "_top",
      data: SIDEBAR_FRAME_DATA
  end

  def sidebar_turbo_frame_tag(src : String? = nil, &) : ERB::SafeString
    turbo_frame_tag "user_sidebar", src: src, target: "_top",
      data: SIDEBAR_FRAME_DATA do
      yield
    end
  end

  def sidebar_page(user : User, placeholders : Array(User)) : Campfire::ResponseCache::Page
    members_by_room = sidebar_direct_members(user)

    # Sorted in Crystal rather than SQL: deterministic order on equal
    # updated_at (ORDER BY does not guarantee it), so the raw
    # /users/me/sidebar response matches the oracle.
    direct_rooms, shared_rooms = Room.visible_for(user).order("id").to_a
      .partition(&.direct?)
    direct_rooms.sort! { |a, b| b.updated_at.as(Time) <=> a.updated_at.as(Time) }
    shared_rooms.sort! { |a, b| a.name.to_s.downcase <=> b.name.to_s.downcase }

    directs = direct_rooms.map do |room|
      members = members_by_room[room.id!]? || [user]
      members = members.reject { |m| m.id == user.id }
      members = [user] if members.empty?
      ChatERB::SidebarDirect.new(room.id!, sidebar_epoch_ms(room),
        sidebar_room_unread?(user, room.id!), members)
    end
    shared = shared_rooms.map do |room|
      ChatERB::SidebarShared.new(room, sidebar_room_unread?(user, room.id!))
    end

    rooms_stream = Turbo::Streams::StreamName.signed_stream_name(["rooms"])
    user_rooms_stream = Turbo::Streams::StreamName.signed_stream_name([user, "rooms"])

    sidebar = ChatERB.new(user: user, directs: directs, shared: shared,
      placeholders: placeholders, rooms_stream: HTML.escape(rooms_stream),
      user_rooms_stream: HTML.escape(user_rooms_stream)).sidebar.to_s

    # Turbo-frame requests (browser reload) get the frame with its block
    # content; a regular GET gets the full layout shell, as in Rails
    # (users/sidebars/show renders sidebar_turbo_frame_tag).
    html = if request.headers["Turbo-Frame"]? == "user_sidebar"
             "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n" +
               sidebar_turbo_frame_tag { ERB::SafeString.new("\n" + sidebar) }.to_s + "\n" +
               "</body>\n</html>\n"
           else
             ChatLayout.page_open("sidebar", "Campfire") +
               sidebar_turbo_frame_tag { ERB::SafeString.new("\n" + sidebar) }.to_s + "\n" +
               ChatLayout.page_close
           end
    Campfire::ResponseCache::Page.new(html)
  end

  private def sidebar_direct_members(user : User) : Hash(Int64, Array(User))
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT mm.room_id, u.id FROM memberships mm
        JOIN users u ON u.id = mm.user_id
        JOIN rooms r ON r.id = mm.room_id
        WHERE r.name IS NULL ORDER BY u.id),
      as: {Int64, Int64})
    return Hash(Int64, Array(User)).new { |h, k| h[k] = [] of User } if rows.empty?
    users_by_id = User.where(id: rows.map(&.[1])).to_a.index_by(&.id!)
    table = Hash(Int64, Array(User)).new { |h, k| h[k] = [] of User }
    rows.each do |(room_id, uid)|
      if (u = users_by_id[uid]?) && u.id != user.id
        table[room_id] << u
      end
    end
    table
  end

  private def sidebar_room_unread?(user : User, room_id : Int64) : Bool
    Membership.where("room_id = ?", room_id)
      .where("user_id = ?", user.id!).unread.any?
  end

  private def sidebar_epoch_ms(room : Room) : Int64
    t = room.updated_at.as(Time)
    (t.to_unix * 1000) + (t.nanosecond // 1_000_000)
  end
end
