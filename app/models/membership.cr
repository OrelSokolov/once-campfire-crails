require "turbo_cr"

class Membership < ActiveRecord::Base
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
end
