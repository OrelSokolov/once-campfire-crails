# BotsHelpers: ERB helpers for app/views/bots/{index,new,edit}.html.erb.
module BotsHelpers
  include ActionController::Helper
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open(title == "Chat bots" ? "bots" : "bot-form",
      title, nav_html: nav_back_to(back_path).raw))
  end

  def copy_button(cmd : String, sr : String) : ERB::SafeString
    button_to_copy_to_clipboard(cmd) do
      ERB::SafeString.new(%(\n#{ChatLayout.icon("copy-paste.svg", 20)}\n<span class="for-screen-reader">#{HTML.escape(sr)}</span>\n))
    end
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
