class Users::SidebarsController < ApplicationController
  helper "users/sidebar"

  DIRECT_PLACEHOLDERS = 20

  def show
    user = current_user!

    page = cache_page("sidebars#show", user.id) do
      sidebar_page(user, find_direct_placeholder_users(user, direct_room_ids(user)))
    end
    send_page(page)
  end

  # Port detects direct rooms via rooms.name IS NULL (the type column
  # stores two spellings, see Room#gid_model_name).
  private def find_direct_placeholder_users(user : User, direct_room_ids : Array(Int64)) : Array(User)
    exclude_user_ids = user_ids_already_in_direct_rooms_with(direct_room_ids)
    limit = {DIRECT_PLACEHOLDERS - exclude_user_ids.size, 0}.max
    return [] of User if limit == 0
    User.active.where.not(id: exclude_user_ids + [user.id!])
      .order("created_at").limit(limit).to_a
  end

  private def direct_room_ids(user : User) : Array(Int64)
    Room.visible_for(user).order("id").to_a
      .select(&.direct?).map(&.id!)
  end

  private def user_ids_already_in_direct_rooms_with(direct_room_ids : Array(Int64)) : Array(Int64)
    ActiveRecord::Base.connection.query_all(
      %(SELECT DISTINCT mm.user_id FROM memberships mm
        JOIN rooms r ON r.id = mm.room_id
        WHERE r.name IS NULL AND mm.room_id IN (#{in_clause(direct_room_ids)})),
      args: direct_room_ids.map { |i| i.as(ActiveRecord::Value) },
      as: {Int64})
  end

  # An empty set becomes IN (NULL), which behaves like WHERE false.
  private def in_clause(ids : Array(Int64)) : String
    ids.empty? ? "NULL" : ids.map { "?" }.join(", ")
  end
end
