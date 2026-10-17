# Логин: форма и создание сессии (Rails-оракул: sessions_controller.rb —
# allow_unauthenticated_access, authenticate_by, start_new_session_for,
# signed permanent cookie session_token). Разметка — app/views/sessions/
# new.html.erb (байт-порт sessions/new.html.erb референса + accounts/
# _help_contact): панель с логотипом аккаунта, поля email/password с
# иконками, кнопка-стрелка; стили/importmap — из ChatLayout (пребилд
# референса в public/assets). create при неудаче рендерит тот же
# шаблон через __render_view("new") с 401.
class SessionsController < ApplicationController
  skip_before_action :require_authentication

  @login_alert : Bool = false
  @account_name : String = ""
  @owner : User? = nil
  @email : String = ""

  def new
    # sessions_controller.rb:27 референса — на чистой установке логин
    # редиректит на first_run.
    return redirect_to "/first_run" if User.count == 0
    prepare_login
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      start_new_session_for user
      redirect_to "/"
    else
      prepare_login(alert: true)
      render(html: __render_view("new").to_s, status: :unauthorized)
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

  # Данные для sessions/new.html.erb: имя аккаунта в легенде, владелец
  # для accounts/_help_contact, email из параметров (value-атрибут).
  private def prepare_login(alert : Bool = false) : Nil
    @login_alert = alert
    account = Account.take
    @account_name = account.try(&.name).to_s
    @owner = User.where("role = ?", 1).order("id").take
    @email = params["email_address"]?.try(&.to_s).to_s
  end

  # ————— ERB-хелперы (app/views/sessions/new.html.erb) —————

  # head без chat-обвязки + turbo-visit-control reload
  # (layouts/application.html.erb логина).
  private def login_head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("Sign in", nil, nil, chat: false,
      head_extra: %(<meta name="turbo-visit-control" content="reload">\n)))
  end

  # flash.now[:alert] (application.html.erb:38-48) — после </nav>.
  private def flash_html : ERB::SafeString
    return ERB::SafeString.new("") unless @login_alert
    ERB::SafeString.new(%(<div class="flash" data-controller="element-removal" data-action="animationend-&gt;element-removal#remove">\n) \
      %(<div class="flash__inner shadow" style="--flash-background: var(--color-negative)">\n) \
      %(<img src="#{ChatLayout.asset("alert.svg")}" aria-hidden="true" width="24" height="24" class="colorize--white">\n) \
      %(</div>\n<span class="for-screen-reader" role="alert" aria-atomic="true">Too many requests or unauthorized.</span>\n</div>\n))
  end

  # panel shake при неудачном входе (class="panel<%= panel_modifier %>").
  private def panel_modifier : String
    @login_alert ? " shake" : " "
  end

  # Логотип аккаунта (logos/app-icon.png, fingerprinted asset).
  private def logo_src : String
    ChatLayout.fresh_account_logo_path(Account.take)
  end

  # value-атрибут email-инпута (пустой, когда параметра нет).
  private def email_value : ERB::SafeString
    return ERB::SafeString.new("") if @email.empty?
    ERB::SafeString.new(%( value="#{HTML.escape(@email)}"))
  end

  private def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end

  private def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  private def lightbox_dialog : ERB::SafeString
    ERB::SafeString.new(ChatLayout.lightbox_dialog)
  end

  private def campfire_icon_src : String
    ChatLayout.asset("campfire-icon.png")
  end

  # Бейдж версии (экранируется в <%= %>).
  private def version : String
    ENV["APP_VERSION"]? || "parity"
  end
end
