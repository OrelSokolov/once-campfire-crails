# GET/PATCH /account(/edit) — account settings: name, room-creation policy, invite link.
# This file sorts first in app/controllers/**, so ApplicationController must be required
# explicitly.
require "./application_controller"

class AccountsController < ApplicationController

  before_action :ensure_can_administer, only: [:update]

  # edit.html.erb footer badge (oracle version_helper.rb).
  helper :version

  # Data for edit.html.erb: account, viewer, the restrict switch, invite link + QR path,
  # and the account's users — admins in the first block, then members, ordered by name.
  @account : Account?
  @user : User?
  @restrict : Bool = false
  @join_url : String = ""
  @admins : Array(User) = [] of User
  @members : Array(User) = [] of User

  # Account nav partial, the invite section (rendered by edit like the
  # oracle's `render "accounts/invite"`), and the user row partial.
  compile_partials({
    "accounts/nav" => {path: "app/views/accounts/_nav.html.erb",
                       locals: {"user" => User}},
    "accounts/invite" => {path: "app/views/accounts/_invite.html.erb",
                          locals: {"url" => String}},
    "accounts/users/user" => {path: "app/views/accounts/users/_user.html.erb",
                              locals: {"user" => User}},
  }, dedent: true)

  def edit
    account = set_account
    user = current_user!
    @user = user
    @restrict = account.settings.restrict_room_creation_to_administrators?
    @join_url = origin + "/join/" + account.join_code.to_s
    users = User.visible_to(user)
    @admins = users.where("role = 1").ordered.to_a
    @members = users.where("role = 0").ordered.to_a
  end

  def update
    account = set_account
    account.update!(account_params)
    redirect_to edit_account_url
  end

  private def set_account : Account
    @account = Account.take
    @account.not_nil!
  end

  # Strong Parameters (Rails account_params): name, logo upload, the
  # settings switch (settings: {}). The logo file reaches the attachment
  # through update!'s logo= setter (has_one_attached).
  private def account_params : ActionController::Parameters
    params.require(:account)
      .permit("name", :logo, {"settings" => {} of String => Array(String)})
  end
end
