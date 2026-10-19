# Логин: форма и создание сессии (Rails-оракул: sessions_controller.rb —
# allow_unauthenticated_access, authenticate_by, start_new_session_for,
# signed permanent cookie session_token). Разметка — app/views/sessions/
# new.html.erb (байт-порт sessions/new.html.erb референса + accounts/
# _help_contact): панель с логотипом аккаунта, поля email/password с
# иконками, кнопка-стрелка; стили/importmap — из ChatLayout (пребилд
# референса в public/assets). create при неудаче рендерит тот же
# шаблон через __render_view("new") с 401.
class SessionsController < ApplicationController
  include SessionsHelpers

  skip_before_action :require_authentication

  attr_reader login_alert : Bool = false
  attr_reader email : String = ""
  @account_name : String = ""
  @owner : User? = nil

  def new
    # sessions_controller.rb:27 референса — на чистой установке логин
    # редиректит на first_run.
    return redirect_to first_run_path if User.count == 0
    prepare_login
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      start_new_session_for user
      redirect_to root_path
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
    redirect_to root_path
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
end
