# RichTextHelper: the editor surface shared by the composer and the
# message edit form (oracle app/helpers/rich_text_helper.rb). Also hosts
# the rich_text_area data-URL defaults — the oracle resolves them through
# the named routes (main_app.rails_direct_uploads_url /
# rails_service_blob_url); the port's active_storage routes carry no
# names, so the URLs are built from the request origin.
module RichTextHelper
  include ActionController::Helper

  def rich_text_data_actions : String
    # submitByKeyboard runs in the capture phase so it can submit on Enter
    # before the editor turns the keystroke into a newline
    "lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture"
  end

  def mention_prompt_tag(room : Room) : ERB::SafeString
    # tag.lexxy_prompt with dash-spelled kwargs (the TagBuilder macro
    # can't re-emit non-identifier NamedTuple keys, so content_tag).
    content_tag("lexxy-prompt", trigger: "@", name: "mention",
      src: autocompletable_users_path(room_id: room.id),
      "remote-filtering": true, "empty-results": "No matches")
  end

  # rich_text_area data-URL defaults (rails_direct_uploads_url /
  # rails_service_blob_url): both render contexts expose `origin` —
  # controllers through SetCurrentRequest, ChatERB through its accessor.
  def rich_text_direct_upload_url : String
    "#{origin}/rails/active_storage/direct_uploads"
  end

  def rich_text_blob_url_template : String
    "#{origin}/rails/active_storage/blobs/redirect/:signed_id/:filename"
  end

  # Oracle RichTextHelper#editable_body (ActionText::Fragment.replace +
  # Content#to_editor_html): every attachment is rebuilt from its
  # attachable before editing — a Trix-era embed carries its details as
  # node attributes the editor doesn't round-trip, a mention edited
  # under Trix carries the generic content type the editor doesn't
  # permit, and a hand-written embed carries whatever markup the author
  # put there. The builders live in ChatLayout (editable_body).
  def editable_body(message : Message) : String
    ChatLayout.editable_body(message.body.to_s)
  end
end
