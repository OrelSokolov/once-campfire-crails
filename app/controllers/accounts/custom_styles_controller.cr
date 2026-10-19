# /account/custom_styles(/edit) — кастомный CSS аккаунта (референс:
# routes.js + custom_styles.eta): textarea account[custom_styles],
# PATCH → UPDATE accounts.custom_styles; layout инжектит <style>
# (см. ChatLayout.head). Только администратор.
# Разметка GET — app/views/accounts/custom_styles/edit.html.erb (implicit render).
class Accounts::CustomStylesController < ApplicationController
  include CustomStylesHelpers

  before_action :require_admin

  # edit.html.erb: аккаунт (текущий CSS в textarea) и viewer.
  @account : Account?
  @user : User?

  def edit
    @account = Account.take.not_nil!
    @user = current_user.not_nil!
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    account = Account.take.not_nil!
    if styles = account_params["custom_styles"]?
      account.custom_styles = styles.to_s
    end
    account.save!
    redirect_to edit_account_custom_styles_path
  end

  # Strong Parameters: textarea account[custom_styles].
  private def account_params : ActionController::Parameters
    params.require("account").permit("custom_styles")
  end
end
