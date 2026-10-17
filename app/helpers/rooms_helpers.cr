# RoomsHelpers — ERB-хелперы app/views/rooms/{new,edit,_form}.html.erb:
# каркас страницы формы комнаты, карточка участника direct-комнаты,
# аватар «Everyone». Включается в RoomsController; общий icon/page_close —
# ViewHelpers (ApplicationController).
module RoomsHelpers
  # head + body + nav (назад на back_path) + main (screen "room-form").
  def page_open(title : String, back_path : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("room-form", title, user.not_nil!,
      nav_html: ChatLayout.nav_back(back_path)))
  end

  # Карточка участника direct-комнаты (avatar_link c lazy-загрузкой).
  def avatar_link(member : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.avatar_link(member, "lazy"))
  end

  def everyone_src : String
    ChatLayout.asset("everyone.svg")
  end
end
