class UsersController < ApplicationController
  # transfer_link (UsersHelper) shares web_share_session_button with the
  # profile views (Rails mixes all helpers into one view context).
  helper "users/profiles"

  # Data for show.html.erb: the viewer (admin branches) and the profile subject.
  @viewer : User?
  @subject : User?

  # Profile nav partial, rendered through the UsersHelper#user_nav wrapper.
  compile_partials({
    "users/nav" => {path: "app/views/users/_nav.html.erb",
                    locals: {"viewer" => User, "subject" => User}},
  }, dedent: true)

  def show
    viewer = current_user!
    @viewer = viewer
    # find-bang: RecordNotFound -> 404 via the middleware rescue ladder
    @subject = User.find(params["id"].to_s)
  end
end
