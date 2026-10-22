# PATCH/DELETE /account/users/:user_id — порт Accounts::UsersController:
# тумблер роли (member/administrator) и деактивация юзера — кнопки в
# списке accounts/edit ( crown-form и minus-button у каждого имени).
# Только администраторы (ensure_can_administer).
class Accounts::UsersController < ApplicationController
  before_action :require_admin

  @target : User? = nil

  # role_params: presence_in(member/administrator) || member.
  def update
    find_target
    role = params.require(:user).permit(:role)["role"]?.to_s
    target = @target.not_nil!
    target.role = role == "administrator" ? 1 : 0
    target.save!
    redirect_to edit_account_url
  end

  # User#deactivate: статус deactivated + удаление сессий (разлогин)
  # + close_remote_connections (user.rb:37 референса) — деактивированный
  # не продолжает слушать комнаты в открытом табе.
  def destroy
    find_target
    target = @target.not_nil!
    target.status = 1
    target.save!
    Session.where("user_id = ?", target.id.not_nil!).delete_all
    target.close_remote_connections
    redirect_to edit_account_url
  end

  # set_user: User.active.find (деактивированных/забаненных менять нельзя).
  private def find_target
    @target = User.where("status = 0 AND id = ?", params["user_id"].to_s).take
  end
end
