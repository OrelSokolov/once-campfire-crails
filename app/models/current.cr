# Per-request globals (oracle current.rb): session/user are set by ApplicationController,
# request by set_current_request; reset between requests by the railties_cr dispatcher.
# Deviation: typed attributes, and the custom `session=` writer that also set user is
# replaced by setting both attributes explicitly in ApplicationController.
class Current < ActiveSupport::CurrentAttributes
  attribute session: Session?, user: User?, request: HTTP::Request?

  def self.request_host : String?
    request.try(&.host)
  end

  def self.request_protocol : String?
    request.try(&.scheme)
  end

  def self.account : Account?
    Account.first
  end
end
