# /session/transfers/:id — авто-логин по ссылке (референс:
# campfire-express routes.js /session/transfers/:id + transfer.eta):
# GET рендерит форму auto-submit (app/views/session_transfers/
# show.html.erb), PUT/PATCH проверяет signed_id (purpose
# "user/transfer"), стартует сессию и редиректит на "/".
class SessionTransfersController < ApplicationController
  skip_before_action :require_authentication

  # show.html.erb: токен из пути (экранируется в action=).
  @token : String = ""

  def show
    @token = params["id"].to_s
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

  # ————— ERB-хелперы (app/views/session_transfers/show.html.erb) —————

  private def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("Session transfer", nil, nil, chat: false))
  end
end
