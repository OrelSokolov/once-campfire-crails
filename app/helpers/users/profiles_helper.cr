# Users::ProfilesHelper: ERB helpers for app/views/users/profiles/show.html.erb.
module Users::ProfilesHelper
  include ActionController::Helper

  # View model of a membership row on the profile page: the oracle renders
  # the users/profiles/_membership partial collection off membership.room
  # (associations preloaded by the controller); the port preloads rooms in
  # one query, so the pair travels as one item (BoostEntry precedent).
  struct MembershipEntry
    attr_reader room : Room
    attr_reader membership : Membership

    def initialize(@room, @membership)
    end
  end

  def install_instructions : ERB::SafeString
    ChatERB.new(ua: @ua).render("install_instructions")
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def web_share_button(url : String) : ERB::SafeString
    web_share_session_button(url, "Your sign-in link",
      "This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out.") do
      ERB::SafeString.new(%(\n<span class="for-screen-reader">Share auto-login link</span>\n#{ChatLayout.icon("share.svg", 20, "flex-item-no-shrink colorize--black")}\n))
    end
  end

  # web_share_session_button lives in ClipboardHelper (globally wired).

  # profile_form_with (oracle users/profiles_helper.rb): form_with model:
  # @user, url: user_profile_path — the FormModel on AR drives the scope
  # and the field values.
  def profile_form_with(**params,
                        &block : ActionView::Helpers::FormHelper::FormBuilder -> _)
    form_with(**params, model: @user.not_nil!, url: user_profile_path,
      method: "patch", data: {controller: "form"}, &block)
  end

  def copy_button(url : String) : ERB::SafeString
    button_to_copy_to_clipboard(url) do
      ERB::SafeString.new(%(\n<span class="for-screen-reader">Copy auto-login link</span>\n#{ChatLayout.icon("copy-paste.svg", 20, "flex-item-no-shrink colorize--black")}\n))
    end
  end

  def profile_display_name(room : Room, viewer : User) : String
    return room.name.to_s unless room.direct?
    others = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ? AND user_id != ?)),
      room.id!, viewer.id!)
      .order("id").map(&.name.to_s)
    ChatLayout.display_sentence(others, viewer.name.to_s)
  end

  # Oracle _membership.html.erb: the involvement chip inside the
  # turbo-frame (involvement_<dom_id>).
  def involvement_chip(room : Room, membership : Membership) : ERB::SafeString
    current = membership.involvement.to_s.presence || "mentions"
    nxt = next_involvement(room, current)
    dom_id = room.dom_id # rooms_<sti>_<id> (model_name.param_key)
    label = ChatLayout::INVOLVEMENT_LABELS[current]? || current
    ERB::SafeString.new(
      %(<turbo-frame id="involvement_#{dom_id}">\n) +
      button_to("/rooms/#{room.id!}/involvement?involvement=#{nxt}",
        method: "put", role: "checkbox",
        aria: {checked: true, labelledby: "involvement_label_#{dom_id}"},
        tabindex: 0, class: "btn #{current}") do
        ERB::SafeString.new(ChatLayout.icon("notification-bell-#{current}.svg") +
          %(<span class="for-screen-reader" id="involvement_label_#{dom_id}">) +
          %(#{HTML.escape(label)}</span>))
      end.raw +
      %(\n</turbo-frame>))
  end

  # Involvement#next: shared rooms cycle mentions -> everything ->
  # nothing -> invisible; direct rooms toggle everything <-> nothing.
  private def next_involvement(room : Room, current : String) : String
    return current == "everything" ? "nothing" : "everything" if room.direct?
    case current
    when "mentions"   then "everything"
    when "everything" then "nothing"
    when "nothing"    then "invisible"
    else                   "mentions"
    end
  end

  # users/profiles/_nav.html.erb: back link + logout form (form_with —
  # the oracle's content_for :nav block).
  def profile_nav : String
    render(partial: "users/profiles/nav").raw
  end
end
