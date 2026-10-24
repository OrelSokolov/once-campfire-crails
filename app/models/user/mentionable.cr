require "../application_record"

class User
  module Mentionable
    MENTION_CONTENT_TYPE = "application/vnd.campfire.mention"

    def attachable_content_type : String
      MENTION_CONTENT_TYPE
    end

    def to_attachable_partial_path : String
      "users/mention"
    end

    # How a mention appears inside the editor, matching the prompt's editor template.
    def to_editor_content_attachment_partial_path : String
      "users/mention"
    end

    def attachable_plain_text_representation(caption : String?) : String
      "@#{name}"
    end
  end
  include Mentionable
end
