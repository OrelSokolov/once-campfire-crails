class Room < ActiveRecord::Base
  has_many :memberships, foreign_key: "room_id"
  has_many :messages, foreign_key: "room_id"
  belongs_to :creator, class_name: "User"

  # Visible rooms for a user, involvement-filtered (sidebar listing).
  def self.visible_for(user : User)
    Room.where(
      %(id IN (SELECT room_id FROM memberships WHERE user_id = ? AND involvement != 'invisible')),
      user.id.not_nil!)
  end
end

# STI-подклассы (колонка type): сид и first_run создают их.
class Rooms::Open < Room
end

class Rooms::Direct < Room
end
