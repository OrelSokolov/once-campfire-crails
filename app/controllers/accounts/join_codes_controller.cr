# POST /account/join_code — порт Accounts::JoinCodesController:
# перегенерация invite-кода (кнопка btn--regenerate в accounts/edit).
# Только администраторы.
class Accounts::JoinCodesController < ApplicationController
  before_action :require_admin

  # Account::Joinable#reset_join_code: SecureRandom.alphanumeric(12)
  # группами по 4 через дефис (CRMu-l8Ge-KB9B).
  def create
    account = Account.take.not_nil!
    account.join_code = generate_join_code
    account.save!
    redirect_to edit_account_url
  end

  private def generate_join_code : String
    chars = ("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a
    code = String.build do |io|
      12.times { io << chars.sample(Random::Secure) }
    end
    code.scan(/.{4}/).join("-")
  end
end
