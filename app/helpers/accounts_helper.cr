# AccountsHelper: ERB helpers for app/views/accounts/edit.html.erb.
module AccountsHelper
  include ActionController::Helper
  def page_open(user : User) : ERB::SafeString
    page_shell_open("Account settings", nav_html: account_nav(user))
  end

  def page_close : ERB::SafeString
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">) +
             version + %(</span></div>)
    page_shell_close(footer)
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  # accounts/_nav.html.erb: back link + admin bots/custom-styles links
  # (link_to do — the oracle's nav block).
  def account_nav(user : User) : String
    render(partial: "accounts/nav", locals: {"user" => user}).raw
  end

  private def last_room_visited_path(user : User) : String
    room = nil
    if last = cookies[:last_room]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= Room.visible_for(user).order("id").first?
    room ? room_path(room.id!) : root_path
  end
end
