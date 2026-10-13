# Логин: форма и создание сессии (Rails-оракул: sessions_controller.rb —
# allow_unauthenticated_access, authenticate_by, start_new_session_for,
# signed permanent cookie session_token).
class SessionsController < ApplicationController
  skip_before_action :require_authentication

  def new
    render(html: <<-HTML
      <!doctype html>
      <html>
      <head><title>Sign in</title></head>
      <body>
        <form method="post" action="/session">
          <input type="email" name="email_address" placeholder="Email" required>
          <input type="password" name="password" placeholder="Password" required>
          <button type="submit">Sign in</button>
        </form>
      </body>
      </html>
    HTML
    )
  end

  def create
    if (user = User.authenticate(params["email_address"].to_s, params["password"].to_s))
      session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
      cookies.signed.set("session_token", session.token.not_nil!,
        expires: Time.utc + 20.years, httponly: true, same_site: :lax)
      redirect_to "/"
    else
      render(html: <<-HTML, status: :unauthorized
        <!doctype html>
        <html>
        <head><title>Sign in</title></head>
        <body>
          <form method="post" action="/session">
            <input type="email" name="email_address" placeholder="Email" required>
            <input type="password" name="password" placeholder="Password" required>
            <button type="submit">Sign in</button>
          </form>
          <p>Too many requests or unauthorized.</p>
        </body>
        </html>
      HTML
      )
    end
  end
end
