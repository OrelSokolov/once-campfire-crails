# Oracle cable_helper.rb: script-aware action cable URL meta tag (the app
# mounts Action Cable at /cable with no script name).
module CableHelper
  include ActionController::Helper

  def script_aware_action_cable_meta_tag : ERB::SafeString
    tag.meta name: "action-cable-url", content: "/cable"
  end
end
