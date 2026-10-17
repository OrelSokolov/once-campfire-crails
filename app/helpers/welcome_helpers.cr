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
end
