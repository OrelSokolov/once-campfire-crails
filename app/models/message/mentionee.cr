require "../application_record"

# Message::Mentionee (message/mentionee.rb): упомянутые в теле
# rich-text пользователи (action-text-attachment sgid).
class Message
  module Mentionee
    # Порт mentionIds (richtext.js): конверт sgid разбирается в
    # ChatLayout.mention_user — как lib/rails_ext/action_text_
    # attachables.rb оракула, подпись для User НЕ проверяется
    # (ротация SECRET_KEY_BASE не ломает упоминания), non-User → nil.
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
