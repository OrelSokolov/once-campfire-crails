# /join/:code — регистрация по invite-ссылке (референс: routes.js
# /join/:code + join.eta): GET — форма name/email/password (app/views/
# joins/show.html.erb), POST — createUser (role=0 + memberships во все
# Rooms::Open, involvement "mentions") + сессия + redirect на "/".
class JoinsController < ApplicationController
  skip_before_action :require_authentication

  # show.html.erb: аккаунт invite-ссылки (имя, join_code в action).
  @account : Account?

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
    @account = account
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
    # STI-порт пишет короткий type ('Open'), сид — полный ('Rooms::Open').
    Room.where("type IN ('Open', 'Rooms::Open')").each do |room|
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

  # ————— ERB-хелперы (app/views/joins/show.html.erb) —————

  # head + body.signup + nav (Sign in на /session/new) + main.
  private def page_open : ERB::SafeString
    account = @account.not_nil!
    nav = %(<div class="flex-item-justify-end"><a href="/session/new" class="btn flex-item-justify-end">) +
      ChatLayout.icon("login-keys.svg") +
      %(<span class="for-screen-reader">Sign in</span></a></div>)
    ERB::SafeString.new(ChatLayout.page_open("join", "Join #{account.name}", nil,
      body_class: "signup", nav_html: nav))
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

  private def app_logo_src : String
    ChatLayout.asset("logos/app-icon.png")
  end

  private def default_avatar_src : String
    ChatLayout.asset("default-avatar.svg")
  end
end
