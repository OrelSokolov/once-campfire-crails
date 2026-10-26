class Sessions::TransfersController < ApplicationController
  helper :session_transfers

  allow_unauthenticated_access

  @token : String = ""

  def show
    @token = params["id"].to_s
  end

  def create
    user_id = verify_signed_id(params["id"].to_s, purpose: "user/transfer")
    user = user_id && User.where("id = ? AND status = 0", user_id).take
    return render(plain: "invalid transfer token", status: 400) unless user

    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    cookies.signed.permanent[:session_token] = { value: session.token!, httponly: true, same_site: :lax }
    redirect_to root_url
  end
end
