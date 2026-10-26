module TrackedRoomVisit
  # Called manually after the page-cache decision (see RoomsController#show),
  # not as a before_action.
  def remember_last_room_visited(room : Room) : Nil
    cookies.permanent[:last_room] = room.id!
  end
end
