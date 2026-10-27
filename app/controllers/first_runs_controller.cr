class FirstRunsController < ApplicationController

  allow_unauthenticated_access
  before_action :prevent_repeats

  @user : User?

  def show
    @user = User.new
  end

  def create
    user = FirstRun.create!(user_params)
    start_new_session_for user

    redirect_to root_url
  rescue ActiveRecord::RecordNotUnique
    redirect_to root_url
  rescue ActiveRecord::RecordInvalid | ActionController::ParameterMissing
    render(plain: "invalid first run parameters", status: :unprocessable_entity)
  end

  private def prevent_repeats
    redirect_to root_url if Account.any?
  end

  # avatar attaches through FirstRun (has_one_attached setter), as in the
  # oracle's User.new(user_params).
  private def user_params : ActionController::Parameters
    params.require(:user).permit(:name, :avatar, :email_address, :password)
  end
end
