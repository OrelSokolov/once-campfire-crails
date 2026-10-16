# Логин: форма и создание сессии (Rails-оракул: sessions_controller.rb —
# allow_unauthenticated_access, authenticate_by, start_new_session_for,
# signed permanent cookie session_token). Форма — порт
# sessions/new.html.erb референса: панель с логотипом аккаунта, поля
# email/password с иконками, кнопка-стрелка; стили/importmap — из
# ChatLayout (пребилд референса в public/assets).
class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
    render_login
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
      cookies.signed.set("session_token", session.token.not_nil!,
        expires: Time.utc + 20.years, httponly: true, same_site: :lax)
      redirect_to "/"
    else
      render_login(alert: true, status: :unauthorized)
    end
  end

  # sessions/new.html.erb + accounts/_help_contact: turbo_page_requires_reload
  # (turbo-visit-control), account_logo_tag (логотип по умолчанию —
  # logos/app-icon.png пребилда), легенда с именем аккаунта,
  # help-contact — mailto administrator'у (role=1: enum member
  # administrator bot) + бейдж версии.
  private def render_login(alert : Bool = false, status : Symbol? = nil) : Nil
    account_name = Account.take.try(&.name).to_s
    owner = User.where("role = ?", 1).order("id").take
    email = HTML.escape(params["email_address"]?.try(&.to_s).to_s)
    shake = alert ? " shake" : ""
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")

    html = String.build do |io|
      io << ChatLayout.head("Sign in", nil, nil, chat: false,
        head_extra: %(<meta name="turbo-visit-control" content="reload">\n))
      io << %(<body data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n</nav>\n)
      io << %(<main id="main-content">\n)
      io << %(<section class="txt-align-center">\n)
      io << %(<div class="panel#{shake}">\n)
      io << %(<figure class="account-logo avatar center margin-block-end txt-xx-large">)
      io << %(<img src="#{ChatLayout.asset("logos/app-icon.png")}" alt="Account logo" width="300" height="300"></figure>\n)
      io << %(<form class="flex flex-column gap" action="/session" accept-charset="UTF-8" method="post">\n)
      io << %(<fieldset class="flex flex-column gap center-block upad">\n)
      io << %(<legend class="txt-large txt-align-center"><strong>) << HTML.escape(account_name) << %(</strong></legend>\n)
      io << %(<div class="flex align-center gap">\n)
      io << %(<label class="flex align-center gap input input--actor txt-large">)
      io << %(<input class="input" type="email" name="email_address" required autofocus)
      io << %( autocomplete="username" placeholder="Enter your email address" value="#{email}">)
      io << %(<img src="#{ChatLayout.asset("email.svg")}" aria-hidden="true" width="24" height="24" class="colorize--black">)
      io << %(</label>\n</div>\n)
      io << %(<div class="flex align-center gap">\n)
      io << %(<label class="flex align-center gap input input--actor txt-large">)
      io << %(<input class="input" type="password" name="password" required)
      io << %( autocomplete="current-password" placeholder="Enter your password" maxlength="72">)
      io << %(<img src="#{ChatLayout.asset("password.svg")}" aria-hidden="true" width="24" height="24" class="colorize--black">)
      io << %(</label>\n</div>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit" name="log_in">)
      io << %(<img src="#{ChatLayout.asset("arrow-right.svg")}" aria-hidden="true">)
      io << %(<span class="for-screen-reader">Go</span></button>\n)
      io << %(</fieldset>\n</form>\n)
      io << %(</div>\n)
      # accounts/_help_contact: administrator mailto + бейдж версии
      if o = owner
        io << %(<div class="txt-align-center margin-block-double full-width">)
        io << %(<a class="btn center" href="mailto:) << HTML.escape(o.email_address.to_s)
        io << %(" title="Email ) << HTML.escape(o.name.to_s) << %(">)
        io << %(<img src="#{ChatLayout.asset("lifebuoy.svg")}" aria-hidden="true">)
        io << %(<span>) << HTML.escape(o.email_address.to_s) << %(</span></a>\n)
        io << %(<div class="txt-align-center center margin-block txt-subtle">Campfire&trade; version )
        io << %(<span class="version-badge">) << version << %(</span></div>\n)
        io << %(</div>\n)
      end
      io << %(</section>\n)
      io << %(<footer id="footer"></footer></main>\n)
      io << %(<aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open"></aside>\n)
      io << %(<a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">)
      io << %(<img alt="Campfire logo" src="#{ChatLayout.asset("campfire-icon.png")}" width="256" height="216"></a>\n)
      io << %(</body></html>\n)
    end

    if status
      render(html: html, status: status)
    else
      render(html: html)
    end
  end
end
