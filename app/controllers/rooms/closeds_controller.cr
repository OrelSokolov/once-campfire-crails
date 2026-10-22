# /rooms/closeds — закрытые комнаты (референс: rooms/closeds_controller.rb):
# new/create/edit/update; общая логика — в базовом RoomsController.
# Membership при создании — выбранные user_ids[] + создатель.
class Rooms::ClosedsController < RoomsController
  before_action :set_room, only: [:edit, :update]
  # closeds_controller.rb:3 оракула: update (переименование + смена
  # состава) — только создатель/админ, иначе участник мог бы выкинуть
  # всех из комнаты.
  before_action :ensure_can_administer, only: [:update]
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # Open and closed rooms convert into each other, so both are in reach here. Direct
  # rooms never are: promoting one would republish its history to the whole account.
  private def room_scope
    Room.where(
      "id IN (SELECT room_id FROM memberships WHERE user_id = ?) AND type NOT IN ('Direct', 'Rooms::Direct')",
      Current.user.not_nil!.id.not_nil!)
  end

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
    prepare_room_form(@room, "closeds", current_user.not_nil!)
  end

  # PATCH /rooms/closeds/:room_id — переименование + sync memberships по
  # user_ids[], broadcast prepend с тем же id — Turbo дедуплицирует и
  # перемещает ссылку.
  def update
    update_room
  end
end
