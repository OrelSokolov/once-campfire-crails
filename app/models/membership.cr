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

  # Relation#joins by belongs_to is unsupported — JOIN with a raw fragment; direct rooms
  # are detected by rooms.name IS NULL (see Room#to_gid_param for the two type spellings).
  scope(:with_ordered_room)    { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").order("LOWER(rooms.name)") }
  scope(:with_direct_rooms)    { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").where("rooms.name IS NULL").order("rooms.updated_at DESC") }
  scope(:without_direct_rooms) { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").where("rooms.name IS NOT NULL") }
  scope(:visible) { where.not(involvement: "invisible") }
  scope(:unread)  { where.not(unread_at: nil) }
  # Membership::Connectable scopes (oracle defines them in the concern).
  scope(:connected)    { where("connected_at >= ?", Time.utc - Connectable::CONNECTION_TTL) }
  scope(:disconnected) { where("connected_at IS NULL OR connected_at < ?", Time.utc - Connectable::CONNECTION_TTL) }

  # memberships.grant_to(users) of the oracle (has_many ... do extension):
  # insert_all with the room's default involvement, duplicates skipped.
  def self.grant_to(room : Room, user_ids : Array(Int64)) : Nil
    now = Time.utc
    user_ids.each do |uid|
      ActiveRecord::Base.connection.exec(
        "insert into memberships (room_id, user_id, involvement, connections, created_at, updated_at) " \
        "values (?, ?, ?, 0, ?, ?) on conflict do nothing",
        room.id.not_nil!, uid, room.default_involvement, now, now)
    end
  end
end
