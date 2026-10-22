# concerns/tracked_room_visit.rb референса: cookies.permanent[:last_room].
# В порте remember вызывается вручную после решения page-cache (см.
# RoomsController#show), а не before_action.
module TrackedRoomVisit
  def remember_last_room_visited(room : Room) : Nil
    cookies.permanent["last_room"] = room.id.not_nil!.to_s
  end
end
