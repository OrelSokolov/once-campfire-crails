# /rooms/opens — открытые комнаты (референс: rooms/opens_controller.rb):
# new/create/edit/update; общая логика (форма, создание, sync членств,
# broadcast) — в базовом RoomsController, как в Rails. Membership при
# создании — все активные юзеры аккаунта.
class Rooms::OpensController < RoomsController
  # Rails rooms/opens_controller.rb: ensure_permission_to_create_rooms
  # на new/create (directs не ограничены — там свой контроллер).
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # GET /rooms/opens/new — форма новой комнаты (rooms/opens/new.html.erb
  # → общий _form.html.erb; данные готовит prepare_room_form).
  def new
    prepare_room_form(nil, "opens", current_user.not_nil!)
  end

  # POST /rooms/opens — создание (registerRoomForms): opens дают
  # membership всем активным юзерам; broadcast prepend ссылки в
  # shared_rooms стрима "rooms"; redirect на /rooms/<id>.
  def create
    user = current_user.not_nil!
    member_ids = User.where("status = 0").map(&.id.not_nil!)
    create_room(Rooms::Open, member_ids, user)
  end

  # GET /rooms/opens/:room_id/edit — та же форма с текущим именем,
  # _method=patch.
  def edit
    user = current_user.not_nil!
    room = Room.find?(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    prepare_room_form(room, "opens", user)
  end

  # PATCH /rooms/opens/:room_id — переименование + broadcast prepend с
  # тем же id — Turbo дедуплицирует и перемещает ссылку (opens не
  # пересобирают членство — см. update_room).
  def update
    update_room
  end
end
