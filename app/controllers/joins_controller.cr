# /join/:code — регистрация по invite-ссылке (референс: routes.js
# /join/:code + join.eta): GET — форма name/email/password, POST —
# createUser (role=0 + memberships во все Rooms::Open, involvement
# "mentions") + сессия + redirect на "/".
class JoinsController < ApplicationController
  skip_before_action :require_authentication

  def show
    # Known-issue (PLAN.md): роутер декодирует path-сегменты через
    # URI.decode_www_form — "+" в join_code превращается в пробел;
    # пробуем оба варианта, пока фикс не в монорепо.
    code = params["code"].to_s
    account = Account.where("join_code = ?", code).take ||
              Account.where("join_code = ?", code.gsub(' ', '+')).take
    return head(:not_found) unless account
    if current_user
      return redirect_to "/"
    end
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.page_open("join", "Join #{account.name}", nil,
        body_class: "welcome",
        nav_html: %(<div class="flex-item-justify-end"><a href="/session/new" class="btn flex-item-justify-end">) +
          ChatLayout.icon("login-keys.svg") +
          %(<span class="for-screen-reader">Sign in</span></a></div>))
      io << %(<form action="/join/) << HTML.escape(account.join_code.to_s)
      io << %(" accept-charset="UTF-8" method="post" class="center">)
      io << %(<section class="nametag u-relative">)
      io << %(<div class="flex justify-center align-center pad-block">)
      io << %(<img src=") << ChatLayout.asset("lanyard.svg")
      io << %(" class="nametag__lanyard" aria-hidden="true"></div>\n)
      io << %(<div class="nametag__inner flex flex-column gap">)
      io << %(<fieldset class="flex flex-column center-block">)
      io << %(<legend class="txt-align-center flex gap"><figure class="account-logo avatar">)
      io << %(<img src=") << ChatLayout.asset("logos/app-icon.png")
      io << %(" alt="Account logo" width="300" height="300"></figure>)
      io << %(<strong class="txt-large">) << HTML.escape(account.name.to_s) << %(</strong></legend>)
      io << %(<label class="align-center center avatar__form gap">)
      io << %(<div class="btn avatar input--file txt-xx-large">)
      io << %(<img src=") << ChatLayout.asset("default-avatar.svg")
      io << %(" aria-hidden="true" alt="Avatar"></div></label></fieldset>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="name" placeholder="Name" autofocus )
      io << %(required data-1p-ignore="true" type="text" name="user[name]" id="user_name">)
      io << ChatLayout.icon("person.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="username" placeholder="Email address" )
      io << %(required type="email" name="user[email_address]" id="user_email_address">)
      io << ChatLayout.icon("email.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="new-password" placeholder="Password" )
      io << %(required maxlength="72" type="password" name="user[password]" id="user_password">)
      io << ChatLayout.icon("password.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit">)
      io << ChatLayout.icon("check.svg") << %(<span class="for-screen-reader">Save</span></button>\n)
      io << %(</section></form>\n)
      io << ChatLayout.page_close
    end)
  end

  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    code = params["code"].to_s
    account = Account.where("join_code = ?", code).take ||
              Account.where("join_code = ?", code.gsub(' ', '+')).take
    return head(:not_found) unless account

    name = nested("name")
    email = nested("email_address")
    password = nested("password")
    if name.empty? || email.empty? || password.empty?
      response.status = :unprocessable_entity
      return render(plain: "invalid join parameters")
    end

    now = Time.utc
    user = User.new(
      name: name,
      email_address: email,
      password_digest: Crypto::Bcrypt::Password.create(password, cost: 10).to_s,
      role: 0,
      status: 0,
      created_at: now, updated_at: now)
    user.save!

    # createUser эталона: membership во все Rooms::Open ("mentions").
    # STI-порт хранит type коротким именем подкласса ("Open").
    Room.where("type = 'Open'").each do |room|
      Membership.new(room_id: room.id.not_nil!, user_id: user.id.not_nil!,
        involvement: "mentions", connections: 0,
        created_at: now, updated_at: now).save!
    end

    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    cookies.signed.set("session_token", session.token.not_nil!,
      expires: Time.utc + 20.years, httponly: true, same_site: :lax)
    redirect_to "/"
  end

  private def nested(key : String) : String
    nested = params["user"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    nested[key]?.to_s
  end
end
