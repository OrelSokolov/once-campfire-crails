# AccountsHelper: ERB helpers for app/views/accounts/edit.html.erb.
module AccountsHelper
  include ActionController::Helper
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
