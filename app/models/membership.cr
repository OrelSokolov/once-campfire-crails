class Membership < ActiveRecord::Base
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
