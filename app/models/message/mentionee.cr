require "../application_record"

class Message
  module Mentionee
    # Unlike the oracle's ActionText attachables, the sgid signature for User is NOT verified,
    # so rotating SECRET_KEY_BASE does not break mentions; non-User attachables resolve to nil.
    def self.mention_ids(body : String) : Set(Int64)
      ids = Set(Int64).new
      body.scan(/<action-text-attachment\b[^>]*\bsgid=["']([^"']+)/) do |match|
        if (gid = match[1]?) && (user = ChatLayout.mention_user(gid))
          ids << user.id!
        end
      end
      ids
    end
  end
end
