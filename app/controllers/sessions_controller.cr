# Логин: форма и создание сессии (Rails-оракул: sessions_controller.rb —
# allow_unauthenticated_access, authenticate_by, start_new_session_for,
# signed permanent cookie session_token). Форма — порт
# sessions/new.html.erb референса: панель с логотипом аккаунта, поля
# email/password с иконками, кнопка-стрелка; стили/importmap — из
# ChatLayout (пребилд референса в public/assets).
class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
    # sessions_controller.rb:27 референса — на чистой установке логин
    # редиректит на first_run.
    return redirect_to "/first_run" if User.count == 0
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

  # sessions#destroy: terminate_current_session + redirect root_url.
  def destroy
    raw = cookies.signed["session_token"]?
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s?
            else nil
            end
    Session.where("token = ?", token).delete_all if token
    cookies.delete("session_token")
    redirect_to "/"
  end

  # sessions/new.html.erb + accounts/_help_contact — байт-порт Rails
  # (свёрено с нормализованными артефактами compare): форма с
  # абсолютным action, translation_button у полей, Rails-форма инпутов
  # (required=, autofocus=, id, size), mailto «"Name" <mail>».
  # flash.now[:alert] (application.html.erb:38-48) — после </nav>.
  private def render_login(alert : Bool = false, status : Symbol? = nil) : Nil
    account = Account.take
    account_name = account.try(&.name).to_s
    owner = User.where("role = ?", 1).order("id").take
    email = params["email_address"]?.try(&.to_s).to_s
    flash_html = alert ? %(<div class="flash" data-controller="element-removal" data-action="animationend-&gt;element-removal#remove">\n) \
      %(<div class="flash__inner shadow" style="--flash-background: var(--color-negative)">\n) \
      %(<img src="#{ChatLayout.asset("alert.svg")}" aria-hidden="true" width="24" height="24" class="colorize--white">\n) \
      %(</div>\n<span class="for-screen-reader" role="alert" aria-atomic="true">Too many requests or unauthorized.</span>\n</div>\n) : ""
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    logo = ChatLayout.fresh_account_logo_path(account)

    html = String.build do |io|
      io << ChatLayout.head("Sign in", nil, nil, chat: false,
        head_extra: %(<meta name="turbo-visit-control" content="reload">\n))
      io << %(<body class="" data-controller="local-time lightbox">\n)
      io << %(<a href="#main-content" class="skip-navigation btn">Skip to main content</a>\n)
      io << %(<nav id="nav">\n</nav>\n)
      io << flash_html
      io << %(<main id="main-content">\n)
      io << %(<section class="txt-align-center">\n)
      io << %(<div class="panel#{alert ? " shake" : " "}">\n)
      io << %(<figure class="account-logo avatar center margin-block-end txt-xx-large">)
      io << %(<img src="#{logo}" alt="Account logo" width="300" height="300"></figure>\n)
      io << %(<form class="flex flex-column gap" action="#{origin}/session" accept-charset="UTF-8" method="post">\n)
      io << %(<fieldset class="flex flex-column gap center-block upad">\n)
      io << %(<legend class="txt-large txt-align-center"><strong>) << HTML.escape(account_name) << %(</strong></legend>\n)
      io << %(<div class="flex align-center gap">\n)
      io << ChatLayout.translation_button("email_address") << "\n"
      io << %(<label class="flex align-center gap input input--actor txt-large">\n)
      io << %(<input class="input" type="email" name="email_address" id="email_address" )
      io << %(required="required" autofocus="autofocus" autocomplete="username" )
      io << %(placeholder="Enter your email address")
      io << %( value="#{HTML.escape(email)}") unless email.empty?
      io << %(>\n)
      io << ChatLayout.icon("email.svg", 24, "colorize--black") << "\n"
      io << %(</label>\n</div>\n)
      io << %(<div class="flex align-center gap">\n)
      io << ChatLayout.translation_button("password") << "\n"
      io << %(<label class="flex align-center gap input input--actor txt-large">\n)
      io << %(<input class="input" type="password" name="password" id="password" )
      io << %(required="required" autocomplete="current-password" )
      io << %(placeholder="Enter your password" maxlength="72" size="72">\n)
      io << ChatLayout.icon("password.svg", 24, "colorize--black") << "\n"
      io << %(</label>\n</div>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit" name="log_in">\n)
      io << ChatLayout.icon("arrow-right.svg", size: nil) << "\n"
      io << %(<span class="for-screen-reader">Go</span>\n</button>      </fieldset>\n)
      io << %(</form>  </div>\n)
      # accounts/_help_contact: administrator mailto + бейдж версии
      if o = owner
        io << %(<div class="txt-align-center margin-block-double full-width">\n)
        io << %(<a class="btn center" href="mailto:&quot;) << HTML.escape(o.name.to_s)
        io << %(&quot; &lt;) << HTML.escape(o.email_address.to_s)
        io << %(&gt;" title="Email ) << HTML.escape(o.name.to_s) << %(">\n)
        io << ChatLayout.icon("lifebuoy.svg", size: nil) << "\n"
        io << %(<span>) << HTML.escape(o.email_address.to_s) << %(</span>\n</a>\n)
        io << %(<div class="txt-align-center center margin-block txt-subtle">Campfire&trade; version )
        io << %(<span class="version-badge">) << version << %(</span></div>\n)
        io << %(</div>\n)
      end
      io << %(</section>\n)
      io << %(<footer id="footer">\n</footer>\n</main>\n)
      io << %(<aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">\n</aside>\n)
      io << ChatLayout.lightbox_dialog
      io << %(<a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">\n)
      io << %(<img alt="Campfire logo" src="#{ChatLayout.asset("campfire-icon.png")}" width="256" height="216">\n</a>\n)
      io << %(</body>\n</html>\n)
    end

    if status
      render(html: html, status: status)
    else
      render(html: html)
    end
  end
end
