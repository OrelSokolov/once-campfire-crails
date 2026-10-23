# POST/DELETE /users/:user_id/ban — порт Users::BansController
# референса: бан (bans из IP-адресов сессий, разлогин, статус banned,
# асинхронное удаление контента джобой) и разбан. Кнопки — в
# users/show.html.erb (Ban/Remove ban, admin-only). Гвард —
# ensure_can_administer (require_admin).
class Users::BansController < ApplicationController
  before_action :require_admin

  # create → @user.ban, redirect_to @user.
  def create
    user = find_user
    return unless user
    user.not_nil!.ban
    Campfire::ResponseCache.invalidate! # write: сброс page+identity кэшей
    redirect_to user_path(user.not_nil!.id.not_nil!)
  end

  # destroy → @user.unban, redirect_to @user.
  def destroy
    user = find_user
    return unless user
    user.not_nil!.unban
    Campfire::ResponseCache.invalidate! # write: сброс page+identity кэшей
    redirect_to user_path(user.not_nil!.id.not_nil!)
  end

  # set_user: User.find(params[:user_id]) — включая забаненных (чтобы
  # админ мог снять бан); 404 как в users#show.
  private def find_user : User?
    user = User.find?(params["user_id"].to_s.to_i64)
    unless user
      response.status = :not_found
      render(plain: "User not found")
    end
    user
  end
end
