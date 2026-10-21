# GET /users/me/sidebar — сайдбар со списком комнат. Тонкий контроллер
# (sidebars_controller.rb референса): данные — scope'ы Membership/User,
# разметка — SidebarsHelpers + ChatERB (users/sidebars/_show.html.erb),
# whole-page кэш — PageCache (around_action :cache_read_response).
class Users::SidebarsController < ApplicationController
  include SidebarsHelpers

  DIRECT_PLACEHOLDERS = 20

  def show
    user = current_user.not_nil!

    page = cache_page("sidebars#show", user.id) do
      sidebar_page(user, find_direct_placeholder_users(user, direct_room_ids(user)))
    end
    send_page(page)
  end

  # find_direct_placeholder_users референса: активные коллеги без
  # существующего ping'а — не из direct-комнат viewer'а и не сам viewer
  # (where.not(id: ...) референса), порядок created_at, лимит 20 минус
  # число исключённых. У порта direct-комнаты определяются по
  # rooms.name IS NULL (type хранит два написания, см. Room#to_gid_param).
  private def find_direct_placeholder_users(user : User, direct_room_ids : Array(Int64)) : Array(User)
    exclude_user_ids = user_ids_already_in_direct_rooms_with(direct_room_ids)
    limit = {DIRECT_PLACEHOLDERS - exclude_user_ids.size, 0}.max
    return [] of User if limit == 0
    User.active.where.not(id: exclude_user_ids + [user.id.not_nil!])
      .order("created_at").limit(limit).to_a
  end

  # Direct-комнаты viewer'а (видимые — как в Room.visible_for).
  private def direct_room_ids(user : User) : Array(Int64)
    Room.visible_for(user).order("id").to_a
      .select(&.direct?).map(&.id.not_nil!)
  end

  private def user_ids_already_in_direct_rooms_with(direct_room_ids : Array(Int64)) : Array(Int64)
    ActiveRecord::Base.connection.query_all(
      %(SELECT DISTINCT mm.user_id FROM memberships mm
        JOIN rooms r ON r.id = mm.room_id
        WHERE r.name IS NULL AND mm.room_id IN (#{in_clause(direct_room_ids)})),
      args: direct_room_ids.map { |i| i.as(ActiveRecord::Value) },
      as: {Int64})
  end

  # IN (...)-список для placeholder-запросов; пустой набор → IN (NULL),
  # как `WHERE false`.
  private def in_clause(ids : Array(Int64)) : String
    ids.empty? ? "NULL" : ids.map { "?" }.join(", ")
  end
end
