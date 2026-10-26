# Keep the template's original indentation: parity baselines fix it.
@[ActionController::NoTemplateDedent]
class Autocompletable::UsersController < ApplicationController
  @users : Array(User) = [] of User
  def index
    user = current_user!
    # The rich text editor's mentions prompt filters with `filter`, the
    # autocomplete inputs with `query`
    filter = (params["filter"]?.presence || params["query"]?.presence).to_s.downcase

    scope = if room_id = params["room_id"]?.try(&.to_s.to_i64?)
              User.where(
                %(id IN (SELECT m.user_id FROM memberships m
                 JOIN memberships me ON me.room_id = m.room_id
                 WHERE me.user_id = ? AND m.room_id = ? AND status = 0)),
                user.id!, room_id)
            else
              User.active
            end
    @users = scope.order("lower(name)").to_a
      .select { |u| u.name.to_s.downcase.includes?(filter) }
      .first(20)

    # <lexxy-prompt-item> elements for the mentions prompt
    accept = request.headers["Accept"]?.to_s
    if accept.includes?("application/json") && !accept.includes?("text/html")
      return render(template: "autocompletable/users/index")
    end
  end

  private def generate_sgid(user_id : Int64) : String
    ChatLayout.attachable_sgid(user_id)
  end
end
