class Users::BansController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_user

  @user : User?

  def create
    user = @user.not_nil!
    user.ban
    redirect_to user_path(user.id!)
  end

  def destroy
    user = @user.not_nil!
    user.unban
    redirect_to user_path(user.id!)
  end

  private def set_user : Nil
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    @user = User.find(params["user_id"].to_s)
  end
end
