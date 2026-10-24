# ERB helpers for app/views/messages/boosts/*.html.erb, included in Messages::BoostsController.
module BoostsHelpers
  include ActionController::Helper
  # index.html.erb: boosts partial. No trailing newline after <%= boosts_dom %> —
  # byte parity with the reference (boosts_dom itself ends its output with "\n").
  def boosts_dom : ERB::SafeString
    ERB::SafeString.new(ChatLayout.boosts_dom(mid.not_nil!, boosts))
  end
end
