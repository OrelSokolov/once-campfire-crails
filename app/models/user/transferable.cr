require "../application_record"

# User::Transferable (user/transferable.rb): transfer_id — signed_id
# purpose "user/transfer" (срок 4 часа) для авто-логин ссылки
# /session/transfers/:id.
class User
  module Transferable
    include ActiveSupport::Concern

    TRANSFER_LINK_EXPIRY = 4.hours

    def transfer_id : String
      CRails.application
        .message_verifier("active_record/signed_id", url_safe: true)
        .generate(id.not_nil!, purpose: "user/transfer",
          expires_in: TRANSFER_LINK_EXPIRY)
    end

    macro included
      extend_class_methods!
    end

    class_methods do
      def verify_transfer_id(token : String) : Int64?
        value = CRails.application.message_verifier("active_record/signed_id",
          url_safe: true).verified_any(token, purpose: "user/transfer")
        if value.nil?
          value = CRails.application.message_verifier("active_record/signed_id",
            digest: :sha1, url_safe: true).verified_any(token, purpose: "user/transfer")
        end
        if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
          return raw.to_i64
        end
        nil
      end

      def find_by_transfer_id(token : String) : User?
        return nil unless (uid = verify_transfer_id(token))
        find?(uid)
      end
    end
  end
  include Transferable
end
