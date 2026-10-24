class Users::BansController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_user

  @user : User?

  def create
    user = @user.not_nil!
    user.ban
    Campfire::ResponseCache.invalidate!
    redirect_to user_path(user.id.not_nil!)
  end

  def destroy
    user = @user.not_nil!
    user.unban
    Campfire::ResponseCache.invalidate!
    redirect_to user_path(user.id.not_nil!)
  end

  private def set_user : Nil
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    @user = User.find(params["user_id"].to_s)
  end
end
