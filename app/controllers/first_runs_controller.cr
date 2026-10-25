class FirstRunsController < ApplicationController

  allow_unauthenticated_access
  before_action :prevent_repeats

  def show
  end

  def create
    Campfire::ResponseCache.invalidate!
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

  # avatar is permitted for parity with the reference; avatar upload (has_secure_*) is
  # not ported and FirstRun ignores the field.
  private def user_params : ActionController::Parameters
    params.require(:user).permit(:name, :avatar, :email_address, :password)
  end
end
