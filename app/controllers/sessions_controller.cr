class SessionsController < ApplicationController

  allow_unauthenticated_access only: [:new, :create]

  rate_limit to: 10, within: 3.minutes, only: [:create], with: :render_rejection

  attr_reader login_alert : Bool = false
  attr_reader email : String = ""
  @account_name : String = ""
  @owner : User? = nil

  def new
    return redirect_to first_run_url if User.count == 0
    prepare_login
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      start_new_session_for user
      redirect_to root_url
    else
      prepare_login(alert: true)
      # The content renders BEFORE the layout block: compile_template and
      # __av_layout share @__erb_buf, a nested render inside the block
      # would clobber the layout's accumulated output.
      content = __render_view("new").to_s
      render(html: __render_layout { content }.to_s, status: :unauthorized)
    end
  end

  def destroy
    if (endpoint = params["push_subscription_endpoint"]?.try(&.to_s.presence)) &&
       (user = current_user)
      Push::Subscription.where("endpoint = ? AND user_id = ?",
        endpoint, user.id!).delete_all
    end
    raw = cookies.signed[:session_token]?
    token = Session.token_from_signed_jar(raw)
    Session.where("token = ?", token).delete_all if token
    cookies.delete(:session_token)
    # The reference's disconnect_remote_connections (terminate_current_session): live
    # sockets of the current user close with reconnect: true, so the client comes back
    # unauthorized and lands on the login page.
    current_user.try(&.reset_remote_connections)
    # The reference's terminate_current_session: Current.session&.destroy! + resetting
    # the attributes (the user is no longer current in this request).
    Current.session = nil
    Current.user = nil
    redirect_to root_url
  end

  # Data for sessions/new.html.erb: account name in the legend, owner for
  # accounts/_help_contact, email from the params (the value attribute).
  # alert drives the layout's flash block (oracle flash.now[:alert]).
  private def prepare_login(alert : Bool = false) : Nil
    @login_alert = alert
    flash.now("alert", "Too many requests or unauthorized.") if alert
    account = Account.take
    @account_name = account.try(&.name).to_s
    @owner = User.where("role = ?", 1).order("id").take
    @email = params["email_address"]?.try(&.to_s).to_s
  end

  # The oracle's render_rejection: the same login form with a status
  # (429 from rate_limit / 401 from a failed sign-in).
  private def render_rejection : Nil
    prepare_login(alert: true)
    content = __render_view("new").to_s
    render(html: __render_layout { content }.to_s, status: :too_many_requests)
  end
end
