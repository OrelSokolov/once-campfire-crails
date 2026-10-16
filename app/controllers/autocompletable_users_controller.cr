# GET /autocompletable/users?filter=&room_id= — подсказки автокомплита
# (референс: routes.js registerUsers + prompt_item.eta): HTML-фрагмент
# lexxy-prompt-item на каждого пользователя (до 20, filter по имени).
class AutocompletableUsersController < ApplicationController
  # jbuilder-вьюха JSON-ветки (show.json.jbuilder)
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
              User.where("status = 0")
            end
    users = scope.order("lower(name)").to_a
      .select { |u| u.name.to_s.downcase.includes?(filter) }
      .first(20)

    # Autocomplete-контроллер шлёт Accept: application/json и парсит
    # JSON (routes.js: req.accepts(["html","json"]) === "json");
    # HTML-ветка (prompt_item.eta) — для серверного рендера.
    accept = request.headers["Accept"]?.to_s
    if accept.includes?("application/json") && !accept.includes?("text/html")
      @users = users
      return render(template: "autocompletable_users/show")
    end

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      users.each do |u|
        sgid = generate_sgid(u.id.not_nil!)
        io << %(<lexxy-prompt-item search=") << HTML.escape(u.name.to_s)
        io << %(" sgid=") << HTML.escape(sgid) << %(">\n)
        io << %(  <template type="menu">)
        io << %(<span class="autocomplete__item flex align-center gap unpad">)
        io << %(<a title=") << HTML.escape(u.name.to_s)
        io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/) << u.id.not_nil!.to_s << %(">)
        io << %(<img aria-hidden="true" src="/users/) << u.id.not_nil!.to_s
        io << %(/avatar" width="48" height="48"></a>)
        io << %(<span class="autocompletable__name">) << HTML.escape(u.name.to_s)
        io << %(</span></span></template>\n)
        io << %(  <template type="editor"></template>\n)
        io << %(</lexxy-prompt-item>\n)
      end
    end)
  end

  # Rails SignedGlobalID (rails.js sgid) — общий генератор в ChatLayout.
  private def generate_sgid(user_id : Int64) : String
    ChatLayout.attachable_sgid(user_id)
  end
end
