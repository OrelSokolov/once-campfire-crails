class Rooms::OpensController < RoomsController
  before_action :set_room, only: [:edit, :update]
  before_action :ensure_can_administer, only: [:update]
  before_action :ensure_permission_to_create_rooms, only: [:new, :create]

  # Open and closed rooms convert into each other, so both are in reach here. Direct
  # rooms never are: promoting one would republish its history to the whole account.
  private def room_scope
    Current.user.not_nil!.rooms.without_directs
  end

  def new
    prepare_room_form(nil, "opens", current_user.not_nil!)
  end

  def create
    user = current_user.not_nil!
    member_ids = User.where("status = 0").map(&.id.not_nil!)
    create_room(Rooms::Open, member_ids, user)
  end

  def edit
    prepare_room_form(@room, "opens", current_user.not_nil!)
  end

  def update
    update_room
  end
end
