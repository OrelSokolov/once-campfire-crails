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
      io << ChatLayout.head("Set up Campfire", nil, nil, chat: false)
      io << %(<body class="welcome">\n<main id="main-content">\n)
      io << %(<form class="center max-width" action="/first_run" accept-charset="UTF-8" method="post">)
      io << %(<section class="flex flex-column gap center-block pad-block">\n)
      io << %(<fieldset class="flex flex-column center-block"><legend class="txt-large txt-align-center"><strong>Set up Campfire</strong></legend></fieldset>\n)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="name" placeholder="Name" autofocus required data-1p-ignore="true" type="text" name="user[name]" id="user_name"></label>\n)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="username" placeholder="Email address" required type="email" name="user[email_address]" id="user_email_address"></label>\n)
      io << %(<label class="flex align-center gap flex-item-grow txt-large input input--actor">)
      io << %(<input class="input" autocomplete="new-password" placeholder="Password" required maxlength="72" type="password" name="user[password]" id="user_password"></label>\n)
      io << %(<button class="btn btn--reversed center txt-large" type="submit">Save</button>\n)
      io << %(</section></form>\n</main>\n</body></html>\n)
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
      involvement: "member", connections: 0,
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
