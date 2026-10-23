require "../application_record"

# User::Mentionable (user/mentionable.rb): аттачабл-упоминание в
# rich-text (@user → attachable content-type + @name в plain text).
class User
  module Mentionable
    MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"

    def attachable_content_type : String
      MENTION_CONTENT_TYPE
    end

    def to_attachable_partial_path : String
      "users/mention"
    end

    # Как упоминание выглядит в редакторе (шаблон промпта).
    def to_editor_content_attachment_partial_path : String
      "users/mention"
    end

    def attachable_plain_text_representation(caption : String?) : String
      "@#{name}"
    end
  end
  include Mentionable
end
