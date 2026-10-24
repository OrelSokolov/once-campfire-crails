class Accounts::JoinCodesController < ApplicationController
  before_action :ensure_can_administer

  def create
    account = Account.take.not_nil!
    account.reset_join_code
    redirect_to edit_account_url
  end
end
