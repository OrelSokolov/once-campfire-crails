# GET/PATCH /account(/edit) — account settings: name, room-creation policy, invite link.
# This file sorts first in app/controllers/**, so ApplicationController must be required
# explicitly.
require "./application_controller"

class AccountsController < ApplicationController

  before_action :ensure_can_administer, only: [:update]

  # Data for edit.html.erb: account, viewer, the restrict switch, invite link + QR path,
  # and the account's users — admins in the first block, then members, ordered by name.
  @account : Account?
  @user : User?
  @restrict : Bool = false
  @join_url : String = ""
  @qr_path : String = ""
  @admins : Array(User) = [] of User
  @members : Array(User) = [] of User

  # Account nav partial and the user row partial for the edit list.
  compile_partials({
    "accounts/nav" => {path: "app/views/accounts/_nav.html.erb",
                       locals: {"user" => User}},
    "accounts/users/user" => {path: "app/views/accounts/users/_user.html.erb",
                              locals: {"user" => User}},
  }, dedent: true)

  def edit
    account = set_account
    user = current_user.not_nil!
    @user = user
    @restrict = account.restrict_room_creation_to_administrators?
    @join_url = origin + "/join/" + account.join_code.to_s
    @qr_path = "/qr_code/" + Base64.urlsafe_encode(@join_url, padding: false)
    users = User.visible_to(user)
    @admins = users.where("role = 1").ordered.to_a
    @members = users.where("role = 0").ordered.to_a
  end

  def update
    Campfire::ResponseCache.invalidate!
    account = set_account
    if name = account_params["name"]?
      account.name = name.to_s
    end
    # restrict_room_creation_to_administrators (settings JSON switch)
    if (settings = account_params["settings"]?).is_a?(ActionController::Parameters) &&
       (value = settings["restrict_room_creation_to_administrators"]?)
      account.restrict_room_creation_to_administrators = value.to_s == "true"
    end
    account.save!
    redirect_to edit_account_url
  end

  private def set_account : Account
    @account = Account.take
    @account.not_nil!
  end

  # Strong Parameters (Rails account_params): name + the restrict switch.
  private def account_params : ActionController::Parameters
    params.require(:account)
      .permit("name", {"settings" => ["restrict_room_creation_to_administrators"]})
  end
end
