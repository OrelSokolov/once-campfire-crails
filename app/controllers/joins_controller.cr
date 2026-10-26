# /join/:code — invite-link sign-up (routes.js + join.eta): GET renders the name/email/
# password form, POST creates the user (role=0 + memberships in every Rooms::Open,
# involvement "mentions") + session + redirect to "/".
class JoinsController < ApplicationController

  allow_unauthenticated_access

  # The invite link's account for show.html.erb (name, join_code in the action).
  attr_reader account : Account?
  @user : User?

  def show
    # Known issue (PLAN.md): the router decodes path segments with URI.decode_www_form,
    # turning "+" in join_code into a space; try both spellings until the fix lands.
    code = params["code"].to_s
    account = Account.where("join_code = ?", code).take ||
              Account.where("join_code = ?", code.gsub(' ', '+')).take
    return head(:not_found) unless account
    if current_user
      return redirect_to root_url
    end
    @account = account
    @user = User.new
  end

  def create
    code = params["code"].to_s
    account = Account.where("join_code = ?", code).take ||
              Account.where("join_code = ?", code.gsub(' ', '+')).take
    return head(:not_found) unless account

    name = nested("name")
    email = nested("email_address")
    password = nested("password")
    if name.empty? || email.empty? || password.empty?
      response.status = :unprocessable_entity
      return render(plain: "invalid join parameters")
    end

    now = Time.utc
    user = User.new(
      name: name,
      email_address: email,
      password_digest: Crypto::Bcrypt::Password.create(password, cost: 10).to_s,
      role: :member,
      created_at: now, updated_at: now)
    # Membership in every open room comes from the model's
    # after_create_commit :grant_membership_to_open_rooms (user.cr).
    user.save!

    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    cookies.signed.permanent[:session_token] = { value: session.token!, httponly: true, same_site: :lax }
    redirect_to root_url
  end

  private def nested(key : String) : String
    nested = params["user"]?
    return "" unless nested.is_a?(ActionController::Parameters)
    nested[key]?.to_s
  end
end
