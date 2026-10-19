# GET /autocompletable/users?filter=&room_id= — подсказки автокомплита
# (референс: routes.js registerUsers + prompt_item.eta): HTML-фрагмент
# lexxy-prompt-item на каждого пользователя (до 20, filter по имени).
# Вывод show.html.erb содержит отступы (перенесён с ними, бейзлайны
# parity их фиксируют) — отключаем dedent implicit-рендера.
@[ActionController::NoTemplateDedent]
class Autocompletable::UsersController < ApplicationController
  # show.json.jbuilder (JSON-ветка) + show.html.erb (HTML-ветка): до 20
  # отфильтрованных юзеров.
  @users : Array(User) = [] of User
  def show
    user = current_user.not_nil!
    filter = (params["filter"]? || params["query"]?).to_s.downcase

    scope = if room_id = params["room_id"]?.try(&.to_s.to_i64?)
              # Участники комнаты, доступной текущему пользователю
              User.where(
                %(id IN (SELECT m.user_id FROM memberships m
                 JOIN memberships me ON me.room_id = m.room_id
                 WHERE me.user_id = ? AND m.room_id = ? AND status = 0)),
                user.id.not_nil!, room_id)
            else
              User.active
            end
    @users = scope.order("lower(name)").to_a
      .select { |u| u.name.to_s.downcase.includes?(filter) }
      .first(20)

    # Autocomplete-контроллер шлёт Accept: application/json и парсит
    # JSON (routes.js: req.accepts(["html","json"]) === "json");
    # HTML-ветка (prompt_item.eta) — для серверного рендера
    # (implicit render → show.html.erb).
    accept = request.headers["Accept"]?.to_s
    if accept.includes?("application/json") && !accept.includes?("text/html")
      return render(template: "autocompletable/users/show")
    end
  end

  # Rails SignedGlobalID (rails.js sgid) — общий генератор в ChatLayout.
  private def generate_sgid(user_id : Int64) : String
    ChatLayout.attachable_sgid(user_id)
  end
end
