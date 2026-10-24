# ERB helper for app/views/first_runs/show.html.erb, included in FirstRunsController.
module FirstRunsHelpers
  include ActionController::Helper
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("first-run", "Set up Campfire",
      body_class: "signup"))
  end
end
