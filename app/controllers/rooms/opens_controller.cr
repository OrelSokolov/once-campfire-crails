# /rooms/opens — открытые комнаты (референс: rooms/opens_controller.rb):
# new/create/edit/update; общая логика — в базовом RoomsController.
# Membership при создании — все активные юзеры аккаунта.
class Rooms::OpensController < RoomsController
  before_action :set_room, only: [:edit, :update]
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # Open and closed rooms convert into each other, so both are in reach here. Direct
  # rooms never are: promoting one would republish its history to the whole account.
  private def room_scope
    Room.where(
      "id IN (SELECT room_id FROM memberships WHERE user_id = ?) AND type NOT IN ('Direct', 'Rooms::Direct')",
      Current.user.not_nil!.id.not_nil!)
  end

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
    prepare_room_form(@room, "opens", current_user.not_nil!)
  end

  # PATCH /rooms/opens/:room_id — переименование + broadcast prepend с
  # тем же id — Turbo дедуплицирует и перемещает ссылку (opens не
  # пересобирают членство — см. update_room).
  def update
    update_room
  end
end
