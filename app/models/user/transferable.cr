require "../application_record"

class User
  module Transferable
    include ActiveSupport::Concern

    TRANSFER_LINK_EXPIRY_DURATION = 4.hours

    def transfer_id : String
      signed_id(purpose: "user/transfer", expires_in: TRANSFER_LINK_EXPIRY_DURATION)
    end

    macro included
      extend_class_methods!
    end

    class_methods do
      def find_by_transfer_id(id : String) : User?
        find_signed(id, purpose: "user/transfer")
      end
    end
  end
  include Transferable
end
