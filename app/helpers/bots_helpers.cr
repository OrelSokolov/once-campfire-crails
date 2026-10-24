# BotsHelpers: ERB helpers for app/views/bots/{index,new,edit}.html.erb.
module BotsHelpers
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open(title == "Chat bots" ? "bots" : "bot-form",
      title, nav_html: ChatLayout.nav_back(back_path)))
  end

  def copy_button(cmd : String, sr : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(cmd, sr, icon_first: true))
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def avatar_link(user : User?, loading : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(user, loading))
  end

  def bot_avatar_src : String
    ChatLayout.asset("default-bot-avatar.svg")
  end
end
