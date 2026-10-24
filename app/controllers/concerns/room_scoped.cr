module RoomScoped
  private def set_room
    room = room_scope.where(id: (params["room_id"]? || params["id"]).to_s.to_i64).first
    if room
      @room = room
    else
      redirect_to root_url, alert: "Room not found or inaccessible"
    end
  end
end
