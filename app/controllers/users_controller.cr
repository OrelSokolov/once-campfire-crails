# GET /users/:id — публичный профиль пользователя (user.eta): аватар,
# имя/bio/email (админу), кнопка Ping (POST /rooms/directs?user_ids[]=),
# transfer-ссылка (админ, transfer_link.eta). Бан не портирован (нет роута).
# Разметка — app/views/users/show.html.erb (implicit render).
class UsersController < ApplicationController
  include UsersHelpers

  # show.html.erb: viewer (ветки admin-блоков) и subject профиля.
  @viewer : User?
  @subject : User?

  # HTML-партиал nav профиля (layout_start Screen "user"): назад +
  # «Edit my profile» для себя; рендерится обёрткой UsersHelpers#user_nav.
  compile_partials({
    "users/nav" => {path: "app/views/users/_nav.html.erb",
                    locals: {"viewer" => User, "subject" => User}},
  }, dedent: true)

  def show
    viewer = current_user.not_nil!
    @viewer = viewer
    id = params["id"].to_s.to_i64?
    subject = id ? User.find?(id) : nil
    unless subject
      response.status = :not_found
      return render(plain: "User not found")
    end
    @subject = subject
  end
end
