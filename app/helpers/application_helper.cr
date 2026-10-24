# Shared ERB helpers for app/views/**, included in ApplicationController.
module ApplicationHelper
  include ActionController::Helper
  def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  # Prebuilt asset path (icons without width/height and other template assets).
  def asset(name : String) : String
    ChatLayout.asset(name)
  end

  # layouts/_body_close with no content blocks (accounts/searches override it).
  def page_close : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_close)
  end

  def lanyard_src : String
    ChatLayout.asset("lanyard.svg")
  end

  def default_avatar_src : String
    ChatLayout.asset("default-avatar.svg")
  end

  def app_logo_src : String
    ChatLayout.asset("logos/app-icon.png")
  end

  def campfire_icon_src : String
    ChatLayout.asset("campfire-icon.png")
  end
end
