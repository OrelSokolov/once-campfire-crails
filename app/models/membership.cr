require "./application_record"
require "turbo_cr"

class Membership < ApplicationRecord
  # broadcast_*_to instance-методы (turbo-rails Broadcastable): directs
  # #create зовёт membership.broadcast_prepend_to ... partial: (local
  # membership Broadcastable подставляет сам).
  include Turbo::Broadcastable

  belongs_to :room
  belongs_to :user

  # Oracle membership.rb: enum :involvement, %w[ invisible nothing mentions
  # everything ].index_by(&:itself), prefix: :involved_in. String-valued
  # ar_enum mirrors it: invalid values raise ArgumentError on write (setter,
  # .new, update); DB reads stay lenient — legacy junk rows return the raw
  # string instead of 500-ing the page (bell icon clamps elsewhere).
  ar_enum :involvement, {invisible: "invisible", nothing: "nothing",
                         mentions: "mentions", everything: "everything"}

  # membership.rb референса: with_ordered_room / with_direct_rooms /
  # without_direct_rooms / visible / unread. Relation#joins по belongs_to
  # пока не поддержан — JOIN сырым фрагментом; direct-комнаты порта
  # определяются по rooms.name IS NULL (type хранит два написания, см.
  # Room#to_gid_param).
  scope(:with_ordered_room)    { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").order("LOWER(rooms.name)") }
  scope(:with_direct_rooms)    { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").where("rooms.name IS NULL").order("rooms.updated_at DESC") }
  scope(:without_direct_rooms) { joins("INNER JOIN rooms ON rooms.id = memberships.room_id").where("rooms.name IS NOT NULL") }
  scope(:visible)              { where("involvement != 'invisible'") }
  scope(:unread)               { where("unread_at IS NOT NULL") }
end
