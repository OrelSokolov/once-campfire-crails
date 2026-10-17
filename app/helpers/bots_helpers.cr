# BotsHelpers — ERB-хелперы app/views/bots/{index,new,edit}.html.erb:
# каркас страницы с nav-назад, copy-кнопка curl-команды, аватар бота.
# Включается в BotsController; общий icon/page_close — ViewHelpers.
module BotsHelpers
  # head + body + nav (назад на back_path) + main.
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open(title == "Chat bots" ? "bots" : "bot-form",
      title, current_user.not_nil!, nav_html: ChatLayout.nav_back(back_path)))
  end

  def copy_button(cmd : String, sr : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(cmd, sr))
  end

  def bot_avatar_src : String
    ChatLayout.asset("default-bot-avatar.svg")
  end
end
