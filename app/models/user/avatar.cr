require "../application_record"

# User::Avatar (user/avatar.rb): публичная ссылка аватара — signed_id
# purpose "user/avatar"; variant :square см. Users::AvatarsController.
class User
  module Avatar
    include ActiveSupport::Concern

    def avatar_token : String
      CRails.application
        .message_verifier("active_record/signed_id", url_safe: true)
        .generate(id.not_nil!, purpose: "user/avatar")
    end

    macro included
      extend_class_methods!
    end

    class_methods do
      def verify_signed_avatar_token(token : String) : Int64?
        # express/verifier: digest sha256, fallback sha1 (ср.
        # verify_signed_id в concerns/authentication).
        value = CRails.application.message_verifier("active_record/signed_id",
          url_safe: true).verified_any(token, purpose: "user/avatar")
        if value.nil?
          value = CRails.application.message_verifier("active_record/signed_id",
            digest: :sha1, url_safe: true).verified_any(token, purpose: "user/avatar")
        end
        if (raw = value.try(&.as_i?)) || (raw = value.try(&.as_s?.try(&.to_i64?)))
          return raw.to_i64
        end
        nil
      end

      def from_avatar_token(token : String) : User?
        return nil unless (uid = verify_signed_avatar_token(token))
        find?(uid)
      end
    end
  end
  include Avatar
end
