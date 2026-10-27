# BotsHelpers: ERB helpers for app/views/accounts/bots/{index,new,edit}.html.erb
# and the _bot/_form partials.
module BotsHelpers
  include ActionController::Helper
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
