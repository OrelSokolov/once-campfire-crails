class Accounts::UsersController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_target, only: [:update, :destroy]

  @target : User? = nil

  def update
    role = params.require(:user).permit(:role)["role"]?.to_s
    target = @target.not_nil!
    target.role = role == "administrator" ? 1 : 0
    target.save!
    redirect_to edit_account_url
  end

  def destroy
    target = @target.not_nil!
    target.status = "deactivated"
    target.save!
    Session.where("user_id = ?", target.id.not_nil!).delete_all
    target.close_remote_connections
    redirect_to edit_account_url
  end

  private def set_target : Nil
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    @target = User.active.find((params["user_id"]? || params["id"]?).to_s)
  end
end
