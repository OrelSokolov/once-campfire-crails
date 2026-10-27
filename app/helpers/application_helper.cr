# Shared ERB helpers for app/views/**, included in ApplicationController.
module ApplicationHelper
  include ActionController::Helper
  include ActionView::Helpers::TagHelper

  # Layout ivars (oracle: views set @page_title/@body_class at the top of
  # the template; page_title_tag/body_classes read them from the layout).
  @page_title : String? = nil
  @body_class : String? = nil

  def icon(name : String, size : Int32? = 20, cls : String? = nil) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.icon(name, size, cls))
  end

  # ————— layouts/application.html.erb (oracle application_helper.rb) —————

  def page_title_tag : ERB::SafeString
    tag.title(@page_title.to_s.presence || "Campfire")
  end

  # safe_join with no separator: both meta tags on one line (the tag()
  # form renders the self-closing `/>` bytes of the reference head).
  def current_user_meta_tags : ERB::SafeString
    if user = Current.user
      tag(:meta, name: "current-user-id", content: user.id.to_s) +
        tag(:meta, name: "current-user-name", content: user.name.to_s)
    else
      ERB::SafeString.new("")
    end
  end

  def custom_styles_tag : ERB::SafeString
    if styles = Current.account.try(&.custom_styles).to_s.presence
      tag.style(ERB::SafeString.new(styles), data: {"turbo_track" => "reload"})
    else
      ERB::SafeString.new("")
    end
  end

  # Oracle: [ @body_class, admin_body_class, account_logo_body_class ].
  def body_classes : String
    [ @body_class, admin_body_class, account_logo_body_class ]
      .compact.join(" ")
  end

  # CSP is not configured — Rails' csp_meta_tag emits nothing.
  def csp_meta_tag : ERB::SafeString
    ERB::SafeString.new("")
  end

  # Rails.configuration.x.vapid.public_key (config/initializers/vapid.rb).
  def vapid_public_key : String
    ChatLayout::VAPID_PUBLIC_KEY
  end

  # The manifest route (format suffix fixed — no route helper in the port).
  def webmanifest_path(format : String = "json") : String
    "/webmanifest.json"
  end

  # stylesheet_link_tag :all / javascript_importmap_tags: the reference
  # prebuild manifest blocks (every link already carries
  # data-turbo-track="reload"; the dashed-kwarg call form of the oracle is
  # not expressible in Crystal kwargs).
  def stylesheet_link_tag(*sources : String | Symbol, **opts) : ERB::SafeString
    ERB::SafeString.new(ChatLayout::STYLESHEETS)
  end

  def javascript_importmap_tags(*args, **opts) : ERB::SafeString
    ERB::SafeString.new(ChatLayout::IMPORTMAP)
  end

  private def admin_body_class : String?
    "admin" if Current.user.try(&.administrator?)
  end

  private def account_logo_body_class : String?
    "account-has-logo" if Current.account.try(&.logo_attachment)
  end

  # Prebuilt asset path (icons without width/height and other template assets).
  def asset(name : String) : String
    ChatLayout.asset(name)
  end

  # Propshaft-style asset resolution for image_tag: "remove.svg" → the
  # manifest-digested /assets/remove-<digest>.svg path (compute_asset_path
  # semantics; the shard's default /images/ prefix doesn't apply — the app
  # serves the reference prebuild manifest).
  def image_tag(source : String, **opts) : ERB::SafeString
    ::ActionView::Helpers::AssetTagHelper.image_tag(
      ChatLayout.asset(source), __av_opts_to_h(opts))
  end

  # Oracle application_helper.rb link_back_to: the form screens' "Go Back"
  # link (image + screen-reader span, no newlines inside <a>).
  def link_back_to(destination : String) : ERB::SafeString
    link_to destination, class: "btn" do
      icon("arrow-left.svg") + tag.span("Go Back", class: "for-screen-reader")
    end
  end

  # Oracle application_helper.rb link_back: referrer-based back link
  # (users/_nav, profiles nav); root_path when the referrer is missing
  # or points at the current page.
  def link_back : ERB::SafeString
    back_url = request.headers["Referer"]?
    back_url = root_path if back_url.nil? || back_url == request_url
    link_back_to back_url
  end

  # Transitional div wrappers: the oracle carries the nav div in each
  # view's content_for :nav; the crails page wrappers hold it until the
  # views go 1:1 ERB (byte layout of the old ChatLayout.nav_back).
  def nav_back_to(destination : String) : ERB::SafeString
    ERB::SafeString.new(%(<div class="flex-item-justify-start">\n) +
      link_back_to(destination).raw + %(\n</div>))
  end

  def nav_back : ERB::SafeString
    ERB::SafeString.new(%(<div class="flex-item-justify-start">\n) +
      link_back.raw + %(\n</div>))
  end

  private def request_url : String
    url = origin + request.path
    url += "?#{request.query}" if request.query.to_s.presence
    url
  end

  # dom_id(room, prefix) — the oracle's RecordIdentifier resolves the STI
  # class (Rooms::Open → rooms_open_5); the port materializes every row as
  # the base Room class, so route through Room#dom_id (STI-type aware).
  # Messages and other non-STI records keep the shard's RecordIdentifier.
  def dom_id(room : Room, prefix : String | Symbol) : String
    "#{prefix}_#{room.dom_id}"
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
