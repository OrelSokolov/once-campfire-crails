# GET/POST /first_run — установка Campfire (референс: first_runs_
# controller.rb + express routes.js): первый запуск создаёт аккаунт,
# админ-пользователя, комнату "All Talk" (Rooms::Open) с membership и
# сразу подписывает сессию. Если аккаунт уже есть — на "/".
# Разметка GET — app/views/first_runs/show.html.erb (implicit render),
# данных экшен не готовит.
class FirstRunsController < ApplicationController
  include FirstRunsHelpers

  skip_before_action :require_authentication
  before_action :prevent_repeats

  def show
  end

  def create
    Campfire::ResponseCache.invalidate! # write: сброс whole-page кэша
    user = FirstRun.create!(user_params)
    start_new_session_for user

    redirect_to root_url
  rescue ActiveRecord::RecordNotUnique
    redirect_to root_url
  rescue ActiveRecord::RecordInvalid | ActionController::ParameterMissing
    # render(plain:) сбрасывает response.status — передаём аргументом
    render(plain: "invalid first run parameters", status: :unprocessable_entity)
  end

  private def prevent_repeats
    redirect_to root_url if Account.any?
  end

  # avatar в permit-списке — паритет референса; загрузка аватара
  # (has_secure_*) не портирована, FirstRun поле игнорирует.
  private def user_params : ActionController::Parameters
    params.require(:user).permit(:name, :avatar, :email_address, :password)
  end
end
