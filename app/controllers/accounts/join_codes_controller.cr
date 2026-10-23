# POST /account/join_code — порт Accounts::JoinCodesController:
# перегенерация invite-кода (кнопка btn--regenerate в accounts/edit).
# Только администраторы.
class Accounts::JoinCodesController < ApplicationController
  before_action :require_admin

  # Account::Joinable#reset_join_code.
  def create
    account = Account.take.not_nil!
    account.join_code = Account::Joinable.generate_join_code
    account.save!
    redirect_to edit_account_url
  end
end
