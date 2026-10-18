# GET /users/me/sidebar — сайдбар со списком комнат (users/sidebars/
# show.html.erb + rooms/_direct|_shared|_direct_placeholder референса;
# разметка — ChatERB-шаблон, контроллер готовит данные).
class Users::SidebarsController < ApplicationController
  def show
    user = current_user.not_nil!

    # Whole-page response cache (как rooms#show): список комнат меняется
    # только write'ами (rooms create/update, MessageCreator) — все сбрасывают
    # PageCache.invalidate!, так что epoch гарантирует свежесть.
    epoch = db_epoch # мемо: require_authentication уже вычислил PRAGMA
    key = PageCache.key("sidebars#show", request, user.id)
    if (cached = PageCache.get(key, epoch))
      return send_page(cached)
    end

    # Участники direct-комнат одним запросом (было N+1).
    members_by_room = direct_members(user)

    # Rails: with_direct_rooms (rooms.updated_at DESC — «свежесть» DM),
    # with_ordered_room (LOWER(name) ASC); в браузере sorted-list всё равно
    # пересортирует, но сырой ответ /users/me/sidebar должен совпадать.
    direct_rooms, shared_rooms = Room.visible_for(user).order("id").to_a
      .partition { |room| room.name.nil? }
    direct_rooms.sort! { |a, b| b.updated_at.as(Time) <=> a.updated_at.as(Time) }
    shared_rooms.sort! { |a, b| a.name.to_s.downcase <=> b.name.to_s.downcase }

    directs = direct_rooms.map do |room|
      members = members_by_room[room.id.not_nil!]? || [user]
      members = members.reject { |m| m.id == user.id }
      members = [user] if members.empty?
      epoch_ms = (room.updated_at.as(Time).to_unix * 1000) +
                 (room.updated_at.as(Time).nanosecond // 1_000_000)
      unread = Membership.where(
        "room_id = ? AND user_id = ? AND unread_at IS NOT NULL",
        room.id.not_nil!, user.id.not_nil!).any?
      ChatERB::SidebarDirect.new(room.id.not_nil!, epoch_ms, unread, members)
    end
    shared = shared_rooms.map do |room|
      unread = Membership.where(
        "room_id = ? AND user_id = ? AND unread_at IS NOT NULL",
        room.id.not_nil!, user.id.not_nil!).any?
      ChatERB::SidebarShared.new(room, unread)
    end

    # Коллеги без существующего ping'а (direct_placeholder): активные
    # не-боты кроме себя и участников существующих direct-комнат.
    placeholder_ids = direct_placeholder_ids(user, directs.map(&.room_id))
    placeholders = placeholder_ids.flat_map { |id| User.where("id = ?", id).to_a }

    rooms_stream = Turbo::Streams::StreamName.signed_stream_name(["rooms"])
    user_rooms_stream = Turbo::Streams::StreamName.signed_stream_name([user, "rooms"])

    view = ChatERB.new(user: user, directs: directs, shared: shared,
      placeholders: placeholders, rooms_stream: HTML.escape(rooms_stream),
      user_rooms_stream: HTML.escape(user_rooms_stream))
    sidebar = view.sidebar.to_s

    # Turbo-запрос фрейма (браузер reload) получает голый фрагмент;
    # обычный GET — полный layout-каркас, как Rails (turbo_frame_tag +
    # layout при отсутствии заголовка Turbo-Frame): title «Campfire»,
    # body class admin без «sidebar», пустые nav/footer/aside.
    html = if request.headers["Turbo-Frame"]? == "user_sidebar"
             "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n" +
               %(<turbo-frame id="user_sidebar">\n) + sidebar + "</turbo-frame>\n</body>\n</html>\n"
           else
             ChatLayout.page_open("sidebar", "Campfire", user) +
               %(<turbo-frame id="user_sidebar" data-turbo-permanent="true" target="_top" ) +
               %(data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" ) +
               %(data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload">\n) +
               sidebar + %(</turbo-frame>\n) +
               ChatLayout.page_close
           end

    page = Campfire::PageCache::Page.new(html)
    # Кэшируем только если БД не менялась за время рендера и ответ чист
    # (200, без Set-Cookie) — иначе старые чтения получат новый epoch.
    if response.headers["Set-Cookie"]?.nil? && PageCache.epoch == epoch
      PageCache.set(key, epoch, page)
    end
    send_page(page)
  end

  # room_id → участники direct-комнаты (User, порядок id), кроме viewer.
  private def direct_members(user : User) : Hash(Int64, Array(User))
    rows = ActiveRecord::Base.connection.query_all(
      %(SELECT mm.room_id, u.id FROM memberships mm
        JOIN users u ON u.id = mm.user_id
        JOIN rooms r ON r.id = mm.room_id
        WHERE r.name IS NULL ORDER BY u.id),
      as: {Int64, Int64})
    table = Hash(Int64, Array(User)).new { |h, k| h[k] = [] of User }
    rows.each do |(room_id, uid)|
      User.where("id = ?", uid).each { |u| table[room_id] << u unless u.id == user.id }
    end
    table
  end

  # find_direct_placeholder_users: активные (status=0, включая ботов) не
  # из direct-комнат viewer'а и не сам viewer, порядок created_at, лимит
  # 20 минус число исключённых (DIRECT_PLACEHOLDERS).
  private def direct_placeholder_ids(user : User, direct_room_ids) : Array(Int64)
    in_list = direct_room_ids.empty? ? "NULL" : direct_room_ids.map { "?" }.join(", ")
    args = [user.id.not_nil!] + direct_room_ids.map { |i| i.as(ActiveRecord::Value) }
    excluded = ActiveRecord::Base.connection.query_all(
      %(SELECT DISTINCT mm.user_id FROM memberships mm
        JOIN rooms r ON r.id = mm.room_id
        WHERE r.name IS NULL AND mm.room_id IN (#{in_list})),
      args: direct_room_ids.map { |i| i.as(ActiveRecord::Value) },
      as: {Int64})
    limit = {20 - excluded.size, 0}.max
    return [] of Int64 if limit == 0
    ActiveRecord::Base.connection.query_all(
      %(SELECT u.id FROM users u
        WHERE u.status = 0 AND u.id != ?
          AND u.id NOT IN (
            SELECT mm.user_id FROM memberships mm
            JOIN rooms r ON r.id = mm.room_id
            WHERE r.name IS NULL AND mm.room_id IN (#{in_list})
          ) ORDER BY u.created_at LIMIT #{limit}),
      args: args, as: {Int64})
  end
end
