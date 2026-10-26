# AccountsHelper: ERB helpers for app/views/accounts/edit.html.erb.
module AccountsHelper
  include ActionController::Helper
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("account", "Account settings",
      nav_html: account_nav(user)))
  end

  def page_close : ERB::SafeString
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">) +
             version + %(</span></div>)
    ERB::SafeString.new(ChatLayout.page_close(footer))
  end

  def copy_button(url : String) : ERB::SafeString
    button_to_copy_to_clipboard(url) do
      ERB::SafeString.new(%(\n<span class="for-screen-reader">Copy join link</span>\n#{ChatLayout.icon("copy-paste.svg", 20, "colorize--black")}\n))
    end
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  # Nav links are literal <a> tags: link_to renders href as the last
  # attribute while the oracle output has href first (byte parity).
  def account_nav(user : User) : String
    render(partial: "accounts/nav", locals: {"user" => user}).raw
  end

  private def last_room_visited_path(user : User) : String
    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= Room.visible_for(user).order("id").first?
    room ? room_path(room.id.not_nil!) : root_path
  end
end
