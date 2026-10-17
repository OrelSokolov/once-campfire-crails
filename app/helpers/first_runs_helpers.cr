# FirstRunsHelpers — ERB-хелперы app/views/first_runs/show.html.erb:
# обёртка страницы первого запуска. Включается в FirstRunsController;
# icon/page_close/lanyard_src/default_avatar_src — общие (ViewHelpers).
module FirstRunsHelpers
  # head + body.signup + пустой nav + main (без user).
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("first-run", "Set up Campfire", nil,
      body_class: "signup"))
  end
end
