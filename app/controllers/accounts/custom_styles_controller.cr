class Accounts::CustomStylesController < ApplicationController
  helper :custom_styles

  before_action :ensure_can_administer

  @account : Account?
  @user : User?

  def edit
    @account = Account.take.not_nil!
    @user = current_user.not_nil!
  end

  def update
    Campfire::ResponseCache.invalidate!
    account = Account.take.not_nil!
    if styles = account_params["custom_styles"]?
      account.custom_styles = styles.to_s
    end
    account.save!
    redirect_to edit_account_custom_styles_url
  end

  # Strong Parameters
  private def account_params : ActionController::Parameters
    params.require(:account).permit(:custom_styles)
  end
end
