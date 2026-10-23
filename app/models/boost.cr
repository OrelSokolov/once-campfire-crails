require "./application_record"
class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User"
end
