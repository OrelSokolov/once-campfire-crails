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
  scope(:visible)              { where("involvement != 'invisible'") }
  scope(:unread)               { where("unread_at IS NOT NULL") }
end
