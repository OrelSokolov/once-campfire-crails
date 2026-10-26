require "../application_record"

class User
  module Avatar
    include ActiveSupport::Concern

    def avatar_token : String
      signed_id(purpose: "user/avatar")
    end

    macro included
      extend_class_methods!
    end

    class_methods do
      def from_avatar_token(sid : String) : User
        find_signed!(sid, purpose: "user/avatar")
      end
    end
  end
  include Avatar
end
