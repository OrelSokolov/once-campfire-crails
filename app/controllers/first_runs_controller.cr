# GET/POST /first_run — установка Campfire (референс: first_runs_
# controller.rb + express routes.js): первый запуск создаёт аккаунт,
# админ-пользователя, комнату "All Talk" (Rooms::Open) с membership и
# сразу подписывает сессию. Если аккаунт уже есть — на "/".
# Разметка GET — app/views/first_runs/show.html.erb (implicit render),
# данных экшен не готовит.
class FirstRunsController < ApplicationController
  skip_before_action :require_authentication
  before_action :prevent_repeats

  def show
  end

  def create
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = FirstRun.create!(user_params)
    start_new_session_for user

    redirect_to "/"
  rescue ActiveRecord::RecordNotUnique
    redirect_to "/"
  rescue ActiveRecord::RecordInvalid | ActionController::ParameterMissing
    # render(plain:) сбрасывает response.status — передаём аргументом
    render(plain: "invalid first run parameters", status: :unprocessable_entity)
  end

  # ————— ERB-хелперы (app/views/first_runs/show.html.erb) —————

  private def prevent_repeats
    redirect_to "/" if Account.any?
  end

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

  # avatar в permit-списке — паритет референса; загрузка аватара
  # (has_secure_*) не портирована, FirstRun поле игнорирует.
  private def user_params : ActionController::Parameters
    params.require("user").permit("name", "avatar", "email_address", "password")
  end
end
