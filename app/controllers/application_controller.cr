abstract class ApplicationController < ActionController::Base
  # layouts/_lightbox — the oracle layout partial (render "layouts/lightbox"),
  # available to every controller via the SessionsHelpers/ChatERB wrappers.
  compile_partials({
    "layouts/lightbox" => {path: "app/views/layouts/_lightbox.html.erb",
                           locals: {} of String => Nil},
  })

  # Non-conventional helper modules: ClipboardHelper/QrCodeHelper are
  # shared across accounts/bots/users views, so wire them globally.
  helper :clipboard, "qr_code"

  include Authentication
  include Authorization
  include SetCurrentRequest
  include TrackedRoomVisit
  include CachedResponses
  include BlockBannedRequests
  include VersionHeaders
  include AllowBrowser

  # turbo-rails includes Turbo::Streams::Broadcasts into ActionController::Base, so
  # controllers call broadcast_*_to directly.
  include Turbo::Streams::Broadcasts

  before_action :set_current_request
  before_action :set_version_headers
  before_action :verify_supported_browser
  before_action :reject_banned_ip
  before_action :require_authentication
  before_action :deny_bots

  # Campfire authentication.rb: protect_from_forgery using: :header_only, with:
  # :exception — the Rails 8.2 Sec-Fetch-Site protection (no form tokens); bot keys
  # in the URL (non-browser) disable it.
  protect_from_forgery using: :header_only, with: :exception, unless: :bot_request?

  # The oracle's forms carry no embedded authenticity_token; Turbo/XHR take the token
  # from csrf_meta_tags and verification is Sec-Fetch-Site (header_only) only.
  protected def __csrf_token_field(action : String, method : String) : String
    ""
  end
end
