require "../application_record"

# Message::Mentionee (message/mentionee.rb): упомянутые в теле
# rich-text пользователи (action-text-attachment sgid).
class Message
  module Mentionee
    # Порт mentionIds (richtext.js): sgid проверяется подписью в
    # ChatLayout.mention_user (Rails to_signed_gid) — неподписанный
    # конверт mention'ом не считается.
    def self.mention_ids(body : String) : Set(Int64)
      ids = Set(Int64).new
      body.scan(/<action-text-attachment\b[^>]*\bsgid=["']([^"']+)/) do |match|
        if (gid = match[1]?) && (user = ChatLayout.mention_user(gid))
          ids << user.id.not_nil!
        end
      end
      ids
    end
  end
end
