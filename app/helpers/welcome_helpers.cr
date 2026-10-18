# WelcomeHelpers — ERB-хелперы app/views/welcome/show.html.erb:
# пустой экран «No rooms yet» (hi, Lonely Lou). Включается в
# WelcomeController; общий campfire_icon_src — ViewHelpers.
module WelcomeHelpers
  # «No rooms yet»: head для пустого message-area-экрана (chat: false).
  def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("No rooms yet", user.not_nil!, nil, chat: false))
  end

  def messages_empty_src : String
    ChatLayout.asset("messages-empty.svg")
  end

  # footer + aside с turbo-frame user_sidebar (src=/users/me/sidebar) +
  # lightbox-диалог + app-logo — как layouts/_body_close референса
  # (welcome/show: content_for :sidebar, sidebar_turbo_frame_tag(src:)).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close("", ChatLayout.chat_sidebar_frame))
  end
end
