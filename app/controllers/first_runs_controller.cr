# GET/POST /first_run — установка Campfire (референс: first_runs_
# controller.rb + express routes.js): первый запуск создаёт аккаунт,
# админ-пользователя, комнату "All Talk" (Rooms::Open) с membership и
# сразу подписывает сессию. Если аккаунт уже есть — на "/".
class FirstRunsController < ApplicationController
  skip_before_action :require_authentication

  def show
    if Account.take
      return redirect_to "/"
    end
    render(html: String.build do |io|
      io << ChatLayout.page_open("first-run", "Set up Campfire", nil, body_class: "welcome")
      io << %(<form class="center max-width" action="/first_run" accept-charset="UTF-8" method="post">)
      io << %(<section class="nametag u-relative">)
      io << %(<div class="flex justify-center align-center pad-block">)
      io << %(<img src=") << ChatLayout.asset("lanyard.svg")
      io << %(" class="nametag__lanyard" aria-hidden="true"></div>\n)
      io << %(<div class="nametag__inner flex flex-column gap">)
      io << %(<fieldset class="flex flex-column center-block">)
      io << %(<legend class="txt-large txt-align-center"><strong>Set up Campfire</strong></legend>)
      io << %(<label class="align-center center avatar__form gap">)
      io << %(<div class="btn avatar input--file txt-xx-large">)
      io << %(<img src=") << ChatLayout.asset("default-avatar.svg")
      io << %(" aria-hidden="true" alt="Add your avatar"></div></label></fieldset>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="name" placeholder="Name" autofocus required data-1p-ignore="true" type="text" name="user[name]" id="user_name">)
      io << ChatLayout.icon("person.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="username" placeholder="Email address" required type="email" name="user[email_address]" id="user_email_address">)
      io << ChatLayout.icon("email.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="new-password" placeholder="Password" required maxlength="72" type="password" name="user[password]" id="user_password">)
      io << ChatLayout.icon("password.svg", 24, "colorize--black") << %(</label></div>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit">)
      io << ChatLayout.icon("check.svg") << %(<span class="for-screen-reader">Save</span></button>\n)
      io << %(</section></form>\n)
      io << ChatLayout.page_close
    end)
  end

  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    if Account.take
      return redirect_to "/"
    end

    name = nested_param("name")
    email = nested_param("email_address")
    password = nested_param("password")
    if name.empty? || email.empty? || password.empty?
      response.status = :unprocessable_entity
      return render(plain: "invalid first run parameters")
    end

    now = Time.utc
    # join_code — base64url без padding (routes.js: randomBytes(18)
    # .toString("base64url")) — безопасен в path.
    account = Account.new(name: "Campfire",
      join_code: Base64.urlsafe_encode(Random::Secure.random_bytes(18), padding: false),
      created_at: now, updated_at: now)
    account.save!

    user = User.new(
      name: name,
      email_address: email,
      password_digest: Crypto::Bcrypt::Password.create(password, cost: 10).to_s,
      role: 1, # admin
      status: 0,
      created_at: now, updated_at: now)
    user.save!

    room = Rooms::Open.new(
      name: "All Talk",
      creator_id: user.id.not_nil!,
      created_at: now, updated_at: now)
    room.save!

    membership = Membership.new(room_id: room.id.not_nil!, user_id: user.id.not_nil!,
      involvement: "mentions", # Room#default_involvement референса
      connections: 0,
      created_at: now, updated_at: now)
    membership.save!

    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    cookies.signed.set("session_token", session.token.not_nil!,
      expires: Time.utc + 20.years, httponly: true, same_site: :lax)
    redirect_to "/"
  end

  private def nested_param(key : String) : String
    nested = params["user"]?
    case nested
    when ActionController::Parameters then nested[key]?.to_s
    else nested.to_s
    end
  end
end
