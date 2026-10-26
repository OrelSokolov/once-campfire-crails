class Rooms::ClosedsController < RoomsController
  before_action :set_room, only: [:edit, :update]
  before_action :ensure_can_administer, only: [:update]
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # Open and closed rooms convert into each other, so both are in reach here. Direct
  # rooms never are: converting one would let its creator revise who's in it.
  private def room_scope
    Current.user!.rooms.without_directs
  end

  def new
    prepare_room_form(Rooms::Closed.new, "closeds", current_user!)
  end

  def create
    user = current_user!
    member_ids = selected_user_ids.unshift(user.id!).uniq!
    create_room(Rooms::Closed, member_ids, user)
  end

  def edit
    prepare_room_form(@room, "closeds", current_user!)
  end

  def update
    update_room
  end
end
