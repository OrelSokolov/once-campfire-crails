# ViewHelpers — общие ERB-хелперы app/views/**, одинаковые у всех
# контроллеров (иконки, дефолтный page_close, asset-пути). Включается
# в ApplicationController; SafeString — сырой HTML из ChatLayout без
# повторного экранирования в <%= %> (как boosts/profiles).
module ViewHelpers
  def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  # layouts/_body_close без контентных блоков (свои футеры —
  # accounts/searches — перекрывают метод в своих модулях).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close)
  end

  def lanyard_src : String
    ChatLayout.asset("lanyard.svg")
  end

  def default_avatar_src : String
    ChatLayout.asset("default-avatar.svg")
  end

  def app_logo_src : String
    ChatLayout.asset("logos/app-icon.png")
  end

  def campfire_icon_src : String
    ChatLayout.asset("campfire-icon.png")
  end
end
