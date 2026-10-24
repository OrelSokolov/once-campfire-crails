# ERB helpers for app/views/welcome/show.html.erb (empty "No rooms yet" screen).
module WelcomeHelpers
  include ActionController::Helper
  def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("No rooms yet", nil, chat: false))
  end

  def messages_empty_src : String
    ChatLayout.asset("messages-empty.svg")
  end

  # footer + aside with the user_sidebar turbo-frame + lightbox + app-logo,
  # as in layouts/_body_close (welcome/show: sidebar_turbo_frame_tag(src:)).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close("", ChatLayout.chat_sidebar_frame))
  end
end
