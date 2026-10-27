# ERB helpers for app/views/welcome/show.html.erb (empty "No rooms yet" screen).
module WelcomeHelpers
  include ActionController::Helper

  def messages_empty_src : String
    ChatLayout.asset("messages-empty.svg")
  end
end
