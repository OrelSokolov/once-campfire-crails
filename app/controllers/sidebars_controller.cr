# GET /users/me/sidebar — сайдбар со списком комнат (users/sidebars/
# show.html.erb + rooms/_direct|_shared|_direct_placeholder референса;
# разметка — ChatERB-шаблон, контроллер готовит данные).
class SidebarsController < ApplicationController
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

    directs = [] of ChatERB::SidebarDirect
    shared = [] of ChatERB::SidebarShared
    Room.visible_for(user).order("id").to_a.each do |room|
      if room.name.nil?
        members = members_by_room[room.id.not_nil!]? || [user]
        members = members.reject { |m| m.id == user.id }
        members = [user] if members.empty?
        epoch_ms = (room.updated_at.as(Time).to_unix * 1000) +
                   (room.updated_at.as(Time).nanosecond // 1_000_000)
        unread = Membership.where(
          "room_id = ? AND user_id = ? AND unread_at IS NOT NULL",
          room.id.not_nil!, user.id.not_nil!).any?
        directs << ChatERB::SidebarDirect.new(room.id.not_nil!, epoch_ms, unread, members)
      else
        unread = Membership.where(
          "room_id = ? AND user_id = ? AND unread_at IS NOT NULL",
          room.id.not_nil!, user.id.not_nil!).any?
        shared << ChatERB::SidebarShared.new(room, unread)
      end
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
    html = "<!doctype html>\n<html>\n<head><title>Sidebar</title></head>\n<body>\n" +
      %(<turbo-frame id="user_sidebar">\n) + view.sidebar.to_s + "</turbo-frame>\n</body>\n</html>\n"

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

  # Активные не-боты без direct-комнаты с viewer'ом (порядок id).
  private def direct_placeholder_ids(user : User, direct_room_ids) : Array(Int64)
    in_list = direct_room_ids.empty? ? "NULL" : direct_room_ids.map { "?" }.join(", ")
    ids = ActiveRecord::Base.connection.query_all(
      %(SELECT u.id FROM users u
        WHERE u.status = 0 AND u.role != 2 AND u.id != ?
          AND u.id NOT IN (
            SELECT mm.user_id FROM memberships mm
            JOIN rooms r ON r.id = mm.room_id
            WHERE r.name IS NULL AND mm.room_id IN (#{in_list})
          ) ORDER BY u.id),
      args: [user.id.not_nil!] + direct_room_ids.map { |i| i.as(ActiveRecord::Value) },
      as: {Int64})
    ids
  end
end
