# ClipboardHelper: the copy-to-clipboard button (port of the Rails oracle
# clipboard_helper.rb — inner markup comes from the caller's block).
# Also hosts web_share_session_button (oracle: Users::ProfilesHelper —
# Rails exposes every helper in every view; the port wires helper modules
# per controller, so the shared share-button lives with the other share
# family helper, globally wired from ApplicationController).
module ClipboardHelper
  include ActionController::Helper

  def button_to_copy_to_clipboard(url : String, &) : ERB::SafeString
    tag.button class: "btn", data: {
      "controller"                     => "copy-to-clipboard",
      "action"                         => "copy-to-clipboard#copy",
      "copy_to_clipboard_success_class" => "btn--success",
      "copy_to_clipboard_content_value" => url,
    } do
      yield
    end
  end

  # Oracle users/profiles_helper.rb web_share_session_button: hidden until
  # Stimulus reveals navigator.share.
  def web_share_session_button(url : String, title : String, text : String, &) : ERB::SafeString
    tag.button class: "btn", hidden: true, data: {
      "controller"          => "web-share",
      "action"              => "web-share#share",
      "web_share_url_value" => url,
      "web_share_text_value" => text,
      "web_share_title_value" => title,
    } do
      yield
    end
  end
end
