# ProfilesHelpers — ERB-хелперы app/views/profiles/show.html.erb:
# head+nav профиля, кнопка копирования auto-login-ссылки, involvement-чипы.
# Включается в ProfilesController; общий icon/page_close — ViewHelpers.
module ProfilesHelpers
  # SafeString: сырой HTML из ChatLayout без повторного экранирования
  # в <%= %> (как boosts).

  # head + body + nav профиля (back + logout) + main (ChatLayout.page_open).
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("profile", user.name.to_s, user,
      nav_html: profile_nav))
  end

  def copy_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy auto-login link"))
  end

  # involvement.eta (статически, без involvement-роута).
  def involvement_chip(room : Room, membership : Membership) : ERB::SafeString
    involvement = membership.involvement.to_s.presence || "mentions"
    human = ChatLayout::INVOLVEMENT_LABELS[involvement]? || involvement
    ERB::SafeString.new(
      %(<turbo-frame id="involvement_room_#{room.id.not_nil!}">) +
      %(<button role="checkbox" aria-checked="true" tabindex="0" class="btn #{involvement}" type="button">) +
      ChatLayout.icon("notification-bell-#{involvement}.svg") +
      %(<span class="for-screen-reader">) + human + %(</span></button></turbo-frame>))
  end

  # profile_nav.eta: назад + logout (кнопка-иконка, форма на /session).
  def profile_nav : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      io << %(<div class="flex-item-justify-end"><form method="post" action="/session">)
      io << %(<input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn">) << ChatLayout.icon("logout.svg")
      io << %(<span class="for-screen-reader">Log out</span></button></form></div>)
    end
  end
end
