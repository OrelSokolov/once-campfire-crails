require "../application_record"

class Account
  module Joinable
    macro included
      # join_code is generated on create (alphanumeric 12, grouped by 4 with dashes).
      before_create { self.join_code = generate_join_code }
    end

    def reset_join_code
      update!({"join_code" => generate_join_code})
    end

    private def generate_join_code : String
      chars = ("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a
      code = String.build do |io|
        12.times { io << chars.sample(Random::Secure) }
      end
      code.scan(/.{4}/).join("-")
    end
  end

  include Joinable
end
