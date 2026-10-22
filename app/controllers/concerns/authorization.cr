# concerns/authorization.rb референса: ensure_can_administer — 403 для
# не-администраторов (role=1) на write-экшенах.
module Authorization
  def require_admin : Nil
    unless current_user.try(&.administrator?)
      render(plain: "forbidden", status: 403)
    end
  end
end
