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
    # _bot.html.erb: <%= image_tag … %> первой, без класса
    ERB::SafeString.new(ChatLayout.copy_button(cmd, sr, icon_first: true))
  end

  # translation_button (translations_helper): details/popup меню переводов.
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end

  # avatar_tag референса (users/avatars_helper): аватар по токен-путя с
  # title «имя – био»; loading: :lazy у ботов.
  def avatar_link(user : User?, loading : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(user, loading))
  end

  def bot_avatar_src : String
    ChatLayout.asset("default-bot-avatar.svg")
  end
end
