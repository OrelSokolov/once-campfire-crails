require "../application_record"

# User::Role (user/role.rb): enum role + can_administer?. The enum itself is
# declared in user.cr — ar_enum runs only in the class body.
class User
  module Role
    def can_administer?(record : Room? = nil) : Bool
      administrator? || record.try(&.creator) == self || record.try(&.new_record?) == true
    end

    def can_administer?(message : Message?) : Bool
      administrator? || message.try(&.creator) == self || message.try(&.new_record?) == true
    end
  end
  include Role
end
