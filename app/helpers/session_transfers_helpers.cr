# SessionTransfersHelpers: ERB helpers for app/views/sessions/transfers/show.html.erb.
module SessionTransfersHelpers
  include ActionController::Helper
  def page_open : ERB::SafeString
    page_shell_open("Campfire")
  end
end
