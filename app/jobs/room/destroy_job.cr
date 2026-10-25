require "../application_job"

class Room::DestroyJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  serialized room: Room, former_member_ids: Array(Int64)

  def self.queue_kind : String
    "room_destroy"
  end

  # The room may already be gone by the time the job runs — the discarded
  # DeserializationError covers it.
  def perform(room : Room, former_member_ids : Array(Int64)) : Nil
    room.reset_remote_connections_of(former_member_ids)
    room.destroy_one_message_at_a_time
  end
end
