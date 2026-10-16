# GET / — корень: redirect в последнюю посещённую комнату (cookie
# last_room, если пользователь её видит), иначе — первая original-комната
# (семантика welcome#show + TrackedRoomVisit из Rails-референса).
class WelcomeController < ApplicationController
  def show
    user = current_user.not_nil!

    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= default_room(user)

    if room
      redirect_to("/rooms/#{room.id.not_nil!}")
    else
      # welcome/show.html.erb: пустой message-area с иконкой и именем
      # юзера для screen-reader (hi, Lonely Lou).
      response.headers["Content-Type"] = "text/html; charset=utf-8"
      render(html: String.build do |io|
        io << ChatLayout.head("No rooms yet", user, nil, chat: false)
        io << %(<body class="sidebar" data-controller="local-time lightbox">\n)
        io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
        io << %(<nav id="nav">\n</nav>\n)
        io << %(<main id="main-content">\n)
        io << %(<div id="message-area" class="message-area">\n)
        io << %(<div class="message-area--empty min-width center">\n)
        io << %(<figure class="center pad">)
        io << %(<img class="colorize--black translucent" aria-hidden="true" src="#{ChatLayout.asset("messages-empty.svg")}">)
        io << %(<span class="for-screen-reader">) << HTML.escape(user.name.to_s) << %(</span>\n)
        io << %(</figure>\n</div>\n</div>\n)
        io << %(<footer id="footer"></footer></main>\n)
        io << %(<aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">)
        io << %(<turbo-frame id="user_sidebar" src="/users/me/sidebar" data-turbo-permanent="true" target="_top" )
        io << %(data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" )
        io << %(data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload"></turbo-frame>)
        io << "</aside>\n"
        io << %(<a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">)
        io << %(<img alt="Campfire logo" src="#{ChatLayout.asset("campfire-icon.png")}" width="256" height="216"></a>\n)
        io << "</body></html>\n"
      end)
    end
  end

  # Current.user.rooms.original — первая original-комната; как fallback
  # берём первую видимую по id.
  private def default_room(user : User) : Room?
    Room.visible_for(user).order("id").first?
  end
end
