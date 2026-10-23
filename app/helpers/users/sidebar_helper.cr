# Users::SidebarHelper — рендер сайдбара /users/me/sidebar (users/sidebars/
# _show.html.erb + rooms/_direct|_shared|_direct_placeholder референса):
# сборка view-моделей ChatERB, turbo-frame-обёртка и layout-каркас.
# Данные готовит Users::SidebarsController, здесь только разметка.
module Users::SidebarHelper
  # Полная HTML-страница сайдбара (кэшируется PageCache в контроллере).
  def sidebar_page(user : User, placeholders : Array(User)) : Campfire::ResponseCache::Page
    members_by_room = sidebar_direct_members(user)

    # Rails: with_direct_rooms (rooms.updated_at DESC — «свежесть» DM),
    # with_ordered_room (LOWER(name) ASC); в браузере sorted-list всё равно
    # пересортирует, но сырой ответ /users/me/sidebar должен совпадать
    # (сортировка в Crystal, а не SQL — детерминированный порядок при
    # равных updated_at, ORDER BY его не гарантирует).
    direct_rooms, shared_rooms = Room.visible_for(user).order("id").to_a
      .partition(&.direct?)
    direct_rooms.sort! { |a, b| b.updated_at.as(Time) <=> a.updated_at.as(Time) }
    shared_rooms.sort! { |a, b| a.name.to_s.downcase <=> b.name.to_s.downcase }

    directs = direct_rooms.map do |room|
      members = members_by_room[room.id.not_nil!]? || [user]
      members = members.reject { |m| m.id == user.id }
      members = [user] if members.empty?
      ChatERB::SidebarDirect.new(room.id.not_nil!, sidebar_epoch_ms(room),
        sidebar_room_unread?(user, room.id.not_nil!), members)
    end
    shared = shared_rooms.map do |room|
      ChatERB::SidebarShared.new(room, sidebar_room_unread?(user, room.id.not_nil!))
    end

    rooms_stream = Turbo::Streams::StreamName.signed_stream_name(["rooms"])
    user_rooms_stream = Turbo::Streams::StreamName.signed_stream_name([user, "rooms"])

    sidebar = ChatERB.new(user: user, directs: directs, shared: shared,
      placeholders: placeholders, rooms_stream: HTML.escape(rooms_stream),
      user_rooms_stream: HTML.escape(user_rooms_stream)).sidebar.to_s

    # Turbo-запрос фрейма (браузерный reload) получает голый фрагмент;
    # обычный GET — полный layout-каркас, как Rails (turbo_frame_tag +
    # layout при отсутствии заголовка Turbo-Frame): title «Campfire»,
    # body class admin без «sidebar», пустые nav/footer/aside.
    html = if request.headers["Turbo-Frame"]? == "user_sidebar"
             "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n" +
               ::Turbo::FramesHelper.turbo_frame_tag("user_sidebar") { ERB::SafeString.new("\n" + sidebar) }.to_s + "\n" +
               "</body>\n</html>\n"
           else
             ChatLayout.page_open("sidebar", "Campfire") +
               ::Turbo::FramesHelper.turbo_frame_tag("user_sidebar", nil, nil, {
                 "target" => "_top",
                 "data"   => {
                   "turbo_permanent"         => true,
                   "controller"              => "rooms-list read-rooms turbo-frame",
                   "rooms_list_unread_class" => "unread",
                   "action"                  => "presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload",
                 },
               }) { ERB::SafeString.new("\n" + sidebar) }.to_s + "\n" +
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
    users_by_id = User.where(id: rows.map(&.[1])).to_a.index_by(&.id.not_nil!)
    table = Hash(Int64, Array(User)).new { |h, k| h[k] = [] of User }
    rows.each do |(room_id, uid)|
      if (u = users_by_id[uid]?) && u.id != user.id
        table[room_id] << u
      end
    end
    table
  end

  # Membership#unread? референса для комнаты viewer'а.
  private def sidebar_room_unread?(user : User, room_id : Int64) : Bool
    Membership.where("room_id = ?", room_id)
      .where("user_id = ?", user.id.not_nil!).unread.any?
  end

  # data-sorted-list-number сайдбара: epoch updated_at комнаты в мс.
  private def sidebar_epoch_ms(room : Room) : Int64
    t = room.updated_at.as(Time)
    (t.to_unix * 1000) + (t.nanosecond // 1_000_000)
  end
end
