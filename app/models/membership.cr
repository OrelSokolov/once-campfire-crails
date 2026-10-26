require "./application_record"
require "turbo_cr"

class Membership < ApplicationRecord
  include Turbo::Broadcastable

  belongs_to :room
  belongs_to :user

  after_destroy_commit { user.try(&.reset_remote_connections) }

  # String-valued ar_enum mirrors the oracle's enum: invalid values raise ArgumentError on
  # write; DB reads stay lenient so legacy junk rows return the raw string, not a 500.
  # prefix: :involved_in → involved_in_invisible?/…! and the involved_in_* scopes.
  ar_enum :involvement, {invisible: "invisible", nothing: "nothing",
                         mentions: "mentions", everything: "everything"},
           prefix: :involved_in

  scope(:with_ordered_room)    { joins(:room).order("LOWER(rooms.name)") }
  scope(:with_direct_rooms)    { joins(:room).merge(Room.directs).order("rooms.updated_at DESC") }
  scope(:without_direct_rooms) { joins(:room).merge(Room.without_directs) }
  scope(:visible) { where.not(involvement: "invisible") }
  scope(:unread)  { where.not(unread_at: nil) }
  # Membership::Connectable scopes (oracle defines them in the concern).
  scope(:connected)    { where("connected_at >= ?", Time.utc - Connectable::CONNECTION_TTL) }
  scope(:disconnected) { where("connected_at IS NULL OR connected_at < ?", Time.utc - Connectable::CONNECTION_TTL) }

  # memberships.grant_to(users) of the oracle (has_many ... do extension):
  # insert_all with the room's default involvement, duplicates skipped.
  def self.grant_to(room : Room, user_ids : Array(Int64)) : Nil
    insert_all(user_ids.map { |uid|
      {"room_id" => room.id!, "user_id" => uid,
       "involvement" => room.default_involvement} of String => ActiveRecord::Value
    })
  end
end
