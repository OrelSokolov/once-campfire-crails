# Oracle version_helper.rb: the version badge span (footer of the account
# settings screen). app_version comes from APP_VERSION (config/app.cr).
module VersionHelper
  include ActionController::Helper

  def version_badge : ERB::SafeString
    tag.span(ENV["APP_VERSION"]? || "parity", class: "version-badge")
  end
end
