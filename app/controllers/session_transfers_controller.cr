# /session/transfers/:id — авто-логин по ссылке (референс:
# campfire-express routes.js /session/transfers/:id + transfer.eta):
# GET рендерит форму auto-submit, PUT/PATCH проверяет signed_id
# (purpose "user/transfer"), стартует сессию и редиректит на "/".
class SessionTransfersController < ApplicationController
  skip_before_action :require_authentication

  def show
    token = params["id"].to_s
    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.head("Session transfer", nil, nil, chat: false)
      io << %(<body>\n<main id="main-content">\n)
      io << %(<form action="/session/transfers/) << HTML.escape(token)
      io << %(" accept-charset="UTF-8" method="post" data-controller="auto-submit">)
      io << %(<input type="hidden" name="_method" value="put"></form>\n)
      io << %(</main>\n</body>\n</html>\n)
    end)
  end

  def create
    user_id = verify_signed_id(params["id"].to_s, purpose: "user/transfer")
    user = user_id && User.where("id = ? AND status = 0", user_id).take
    return render(plain: "invalid transfer token", status: 400) unless user

    session = Session.start!(user, request.headers["User-Agent"]?, remote_ip)
    cookies.signed.set("session_token", session.token.not_nil!,
      expires: Time.utc + 20.years, httponly: true, same_site: :lax)
    redirect_to "/"
  end
end
