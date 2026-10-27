module RoomScoped
  private def set_room
    # Oracle's rooms_controller.rb#set_room: the membership-scoped lookup is
    # snapshotted in RecordCache — the room_scope query does not run on every
    # request (read paths are cached by db-epoch, like the oracle).
    room = RecordCache.fetch(
      ["room", self.class.name, Current.user!.id!.to_s,
       (params["room_id"]? || params["id"]).to_s],
      read_record_cache_version
    ) { [room_scope.where(id: (params["room_id"]? || params["id"]).to_s.to_i64).first] of ActiveRecord::Base? }.first
    if room
      @room = room.as(Room)
    else
      redirect_to root_url, alert: "Room not found or inaccessible"
    end
  end
end
