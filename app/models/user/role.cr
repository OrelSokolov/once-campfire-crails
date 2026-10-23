require "../application_record"

# User::Role (user/role.rb): enum role (0 member / 1 administrator /
# 2 bot) + can_administer?.
class User
  module Role
    def administrator? : Bool
      role == 1
    end

    def can_administer?(record : Room? = nil) : Bool
      administrator? || record.try(&.creator) == self || record.try(&.new_record?) == true
    end

    def can_administer?(message : Message?) : Bool
      administrator? || message.try(&.creator) == self || message.try(&.new_record?) == true
    end
  end
  include Role
end
