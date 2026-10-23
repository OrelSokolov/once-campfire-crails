require "../application_record"

# Account::Joinable (account/joinable.rb): invite-код аккаунта —
# SecureRandom.alphanumeric(12) группами по 4 через дефис (CRMu-l8Ge-KB9B).
class Account
  module Joinable
    def self.generate_join_code : String
      chars = ("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a
      code = String.build do |io|
        12.times { io << chars.sample(Random::Secure) }
      end
      code.scan(/.{4}/).join("-")
    end
  end
end
