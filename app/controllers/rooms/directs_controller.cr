class Rooms::DirectsController < ApplicationController
  include UserIdsParams
  include RoomsHelper

  @user : User?
  @room : Room?
  @direct : Bool = false
  @direct_title : String = ""
  @direct_members : Array(User) = [] of User
  # Exposed for RoomsHelper#page_open, which cannot access @user directly.
  attr_reader :user

  def new
    @user = current_user.not_nil!
  end

  def edit
    user = current_user.not_nil!
    room = user.rooms.directs.find?(params["room_id"].to_s)
    return head(:not_found) unless room
    @user = user
    @room = room
    @direct = true
    members = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ?)),
      room.id.not_nil!).order("id").to_a
    uid = user.id.not_nil!
    others = members.reject { |m| m.id == uid }.map(&.name.to_s)
    @direct_title = ChatLayout.display_sentence(others, user.name.to_s)
    @direct_members = members.size > 1 ? members.reject { |m| m.id == uid } : members
  end

  def create
    Campfire::ResponseCache.invalidate!
    user = current_user.not_nil!
    ids = selected_user_ids.unshift(user.id.not_nil!).uniq!
    ids.reject! { |id| User.where("id = ? AND status = 0", id).take.nil? }

    room = find_existing_direct(ids)
    unless room
      now = Time.utc
      room = Rooms::Direct.new(creator_id: user.id.not_nil!,
        created_at: now, updated_at: now)
      room.save!
      ids.each do |member_id|
        Membership.new(room_id: room.id.not_nil!, user_id: member_id,
          involvement: room.default_involvement, connections: 0,
          created_at: now, updated_at: now).save!
      end
      broadcast_direct_link(room)
    end
    redirect_to room_url(room.id)
  end

  # Not named `head`: it would shadow the framework's head(status).
  private def page_head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("New ping", nil, chat: false))
  end

  # Matches routes.js: GROUP BY room HAVING COUNT=? AND SUM(user_id IN ...)=?;
  # ids are Int64-only, so interpolation is safe.
  private def find_existing_direct(ids : Array(Int64)) : Room?
    id_list = ids.join(", ")
    Room.where(
      %(id IN (SELECT m.room_id FROM memberships m JOIN rooms r ON r.id = m.room_id
        WHERE r.type = 'Direct'
        GROUP BY m.room_id HAVING COUNT(*) = #{ids.size} AND SUM(m.user_id IN (#{id_list})) = #{ids.size}))).take
  end

  # Like Rails broadcast_create_room: membership.broadcast_prepend_to
  # membership.user, :rooms, target: :direct_rooms, partial:
  # "users/sidebars/rooms/direct".
  private def broadcast_direct_link(room : Room) : Nil
    room.memberships.each do |membership|
      membership.broadcast_prepend_to [membership.user.not_nil!, "rooms"],
        target: :direct_rooms, partial: "users/sidebars/rooms/direct"
    end
  end
end
