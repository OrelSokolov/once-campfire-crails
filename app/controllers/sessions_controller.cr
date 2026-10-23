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

  # sessions_controller.rb:2 оракула: allow_unauthenticated_access
  # ONLY new/create — destroy требует авторизации (Current.user обязан
  # быть установлен до удаления сессии, иначе теряем, кого дисконнектить).
  skip_before_action :require_authentication, only: [:new, :create]

  # sessions_controller.rb:3 оракула: rate_limit to: 10, within:
  # 3.minutes on create — брутфорс пароля. Over-limit → тот же
  # render_rejection (429 + форма логина с flash).
  rate_limit to: 10, within: 3.minutes, only: [:create], with: :render_rejection

  attr_reader login_alert : Bool = false
  attr_reader email : String = ""
  @account_name : String = ""
  @owner : User? = nil

  def new
    # sessions_controller.rb:27 референса — на чистой установке логин
    # редиректит на first_run.
    return redirect_to first_run_url if User.count == 0
    prepare_login
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      start_new_session_for user
      redirect_to root_url
    else
      prepare_login(alert: true)
      render(html: __render_view("new").to_s, status: :unauthorized)
    end
  end

  # sessions#destroy: remove_push_subscription (endpoint из скрытого
  # поля формы логаута — sessions-JS отписывает браузер при выходе) +
  # terminate_current_session + redirect root_url.
  def destroy
    if (endpoint = params["push_subscription_endpoint"]?.try(&.to_s.presence)) &&
       (user = current_user)
      Push::Subscription.where("endpoint = ? AND user_id = ?",
        endpoint, user.id.not_nil!).delete_all
    end
    raw = cookies.signed["session_token"]?
    token = case raw
            when String then raw
            when JSON::Any then raw.as_s?
            else nil
            end
    Session.where("token = ?", token).delete_all if token
    cookies.delete("session_token")
    # disconnect_remote_connections референса (terminate_current_
    # session): live-сокеты текущего юзера закрываются, reconnect: true —
    # клиент вернётся уже неавторизованным и уйдёт на логин.
    current_user.try(&.reset_remote_connections)
    # terminate_current_session референса: Current.session&.destroy! +
    # сброс атрибутов (user больше не текущий в этом запросе).
    Current.session = nil
    Current.user = nil
    redirect_to root_url
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

  # render_rejection оракула: flash + та же форма логина со статусом
  # (429 от rate_limit / 401 от неудачного входа).
  private def render_rejection : Nil
    prepare_login(alert: true)
    render(html: __render_view("new").to_s, status: :too_many_requests)
  end
end
