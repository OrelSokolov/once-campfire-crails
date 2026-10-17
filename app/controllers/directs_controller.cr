# /rooms/directs — личные чаты (референс: registerRoomForms kind=
# "directs" + direct_new.eta): new — форма автокомплита в turbo-frame
# direct_rooms_control; create — найти существующую direct-комнату с
# ровно этим набором участников или создать (membership "everything").
class DirectsController < ApplicationController
  # new.html.erb: viewer (для head-метаданных).
  @user : User?

  # GET /rooms/directs/new — форма (подменяет direct_rooms_control в
  # сайдбаре через data-turbo-frame="_self"). Разметка — app/views/
  # directs/new.html.erb (implicit render).
  def new
    @user = current_user.not_nil!
  end

  # POST /rooms/directs — существующая комната с тем же набором участников
  # или новая Rooms::Direct (name NULL, involvement "everything").
  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
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
          involvement: "everything", connections: 0,
          created_at: now, updated_at: now).save!
      end
      broadcast_direct_link(room)
    end
    redirect_to "/rooms/#{room.id}"
  end

  # GET /rooms/directs/new — head для формы (chat: false).
  private def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("New ping", @user.not_nil!, nil, chat: false))
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  # Форма шлёт повторяющиеся user_ids[]: парсер кладёт их в
  # params["user_ids"] (Scalar при одном значении, Array — при
  # нескольких); user_ids[] ключ тоже поддерживаем.
  private def selected_user_ids : Array(Int64)
    ids = [] of Int64
    add = ->(v : String) do
      if (parsed = v.to_i64?)
        ids << parsed
      end
    end
    case value = params["user_ids"]? || params["user_ids[]"]?
    when ActionController::Parameters::Scalar then add.call(value.to_s)
    when Array
      value.each { |v| add.call(v.to_s) }
    when ActionController::Parameters
      value.parameters.each_value do |v|
        case v
        when ActionController::Parameters::Scalar then add.call(v.to_s)
        when Array then v.each { |e| add.call(e.to_s) }
        end
      end
    end
    ids
  end

  # Как routes.js: GROUP BY room HAVING COUNT=? AND SUM(user_id IN ...)=?
  # (STI-порт хранит type коротким именем — "Direct"). ids — только
  # Int64 (из to_i64?), интерполяция безопасна.
  private def find_existing_direct(ids : Array(Int64)) : Room?
    id_list = ids.join(", ")
    Room.where(
      %(id IN (SELECT m.room_id FROM memberships m JOIN rooms r ON r.id = m.room_id
        WHERE r.type = 'Direct'
        GROUP BY m.room_id HAVING COUNT(*) = #{ids.size} AND SUM(m.user_id IN (#{id_list})) = #{ids.size}))).take
  end

  # Как Rails broadcast_create_room: membership.broadcast_prepend_to
  # membership.user, :rooms, target: :direct_rooms, partial:
  # "users/sidebars/rooms/direct" — Broadcastable сам подставляет local
  # membership; стрим gid://campfire/User/<id> base64 + ":rooms";
  # партиал рендерит ChatERB (Turbo.partial_renderer).
  private def broadcast_direct_link(room : Room) : Nil
    room.memberships.each do |membership|
      membership.broadcast_prepend_to [membership.user.not_nil!, "rooms"],
        target: :direct_rooms, partial: "users/sidebars/rooms/direct"
    end
  end
end
