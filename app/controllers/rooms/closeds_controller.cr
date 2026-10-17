# /rooms/closeds — закрытые комнаты (референс: rooms/closeds_controller.rb):
# new/create/edit/update; общая логика — в базовом RoomsController, как в
# Rails. Membership при создании — выбранные user_ids[] + создатель.
class Rooms::ClosedsController < RoomsController
  # Rails rooms/closeds_controller.rb: ensure_permission_to_create_rooms
  # на new/create.
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # GET /rooms/closeds/new — форма новой комнаты (rooms/closeds/new.html.erb
  # → общий _form.html.erb; данные готовит prepare_room_form).
  def new
    prepare_room_form(nil, "closeds", current_user.not_nil!)
  end

  # POST /rooms/closeds — создание: membership выбранным user_ids[]
  # (плюс создатель); broadcast prepend ссылки в shared_rooms стрима
  # "rooms"; redirect на /rooms/<id>.
  def create
    user = current_user.not_nil!
    member_ids = selected_user_ids.unshift(user.id.not_nil!).uniq!
    create_room(Rooms::Closed, member_ids, user)
  end

  # GET /rooms/closeds/:room_id/edit — форма с текущим именем и списком
  # доступа (выбранные первыми — делит divider в _form).
  def edit
    user = current_user.not_nil!
    room = Room.find?(params["room_id"].to_s.to_i64)
    return head(:not_found) unless room
    prepare_room_form(room, "closeds", user)
  end

  # PATCH /rooms/closeds/:room_id — переименование + sync memberships по
  # user_ids[], broadcast prepend с тем же id — Turbo дедуплицирует и
  # перемещает ссылку.
  def update
    update_room
  end
end
