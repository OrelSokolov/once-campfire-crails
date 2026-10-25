# ClipboardHelper: the copy-to-clipboard button (port of the Rails oracle
# clipboard_helper.rb — inner markup comes from the caller's block).
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
end
