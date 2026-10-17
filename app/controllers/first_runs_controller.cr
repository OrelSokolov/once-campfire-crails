# GET/POST /first_run — установка Campfire (референс: first_runs_
# controller.rb + express routes.js): первый запуск создаёт аккаунт,
# админ-пользователя, комнату "All Talk" (Rooms::Open) с membership и
# сразу подписывает сессию. Если аккаунт уже есть — на "/".
# Разметка GET — app/views/first_runs/show.html.erb (implicit render),
# данных экшен не готовит.
class FirstRunsController < ApplicationController
  skip_before_action :require_authentication

  def show
    return redirect_to "/" if Account.take
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

  # ————— ERB-хелперы (app/views/first_runs/show.html.erb) —————

  # head + body.signup + пустой nav + main (без user).
  private def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("first-run", "Set up Campfire", nil,
      body_class: "signup"))
  end

  private def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close)
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  private def lanyard_src : String
    ChatLayout.asset("lanyard.svg")
  end

  private def default_avatar_src : String
    ChatLayout.asset("default-avatar.svg")
  end

  private def nested_param(key : String) : String
    nested = params["user"]?
    case nested
    when ActionController::Parameters then nested[key]?.to_s
    else nested.to_s
    end
  end
end
