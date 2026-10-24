# Users::ProfilesHelper: ERB helpers for app/views/users/profiles/show.html.erb.
module Users::ProfilesHelper
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("profile", user.name.to_s,
      nav_html: profile_nav))
  end

  def install_instructions : ERB::SafeString
    ChatERB.new(ua: @ua).render("install_instructions")
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def fresh_avatar_path(user : User) : String
    ChatLayout.fresh_user_avatar_path(user.id.not_nil!, user.updated_at)
  end

  def web_share_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.web_share_button(url))
  end

  # No FormModel for User in the port: field values are passed
  # explicitly via value:.
  def profile_form_with(**params,
                        &block : ActionView::Helpers::FormHelper::FormBuilder -> _)
    form_with **params, url: "/users/me/profile", method: "patch",
      scope: "user", data: {controller: "form"}, &block
  end

  def copy_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy auto-login link",
      icon_class: "flex-item-no-shrink colorize--black"))
  end

  def profile_display_name(room : Room, viewer : User) : String
    return room.name.to_s unless room.direct?
    others = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ? AND user_id != ?)),
      room.id.not_nil!, viewer.id.not_nil!)
      .order("id").map(&.name.to_s)
    ChatLayout.display_sentence(others, viewer.name.to_s)
  end

  def membership_row(room : Room, membership : Membership,
                     viewer : User) : ERB::SafeString
    name = HTML.escape(profile_display_name(room, viewer))
    ERB::SafeString.new(
      %(<li class="flex align-center gap margin-none min-width membership-item">\n) +
      %(<a class="overflow-ellipsis fill-shade txt-primary txt-undecorated" href="#{room_path(room.id.not_nil!)}">\n) +
      %(<strong>#{name}</strong>\n</a>\n) +
      %(<hr aria-hidden="true" class="separator">\n) +
      %(<span class="txt-small">\n) +
      involvement_chip(room, membership).raw +
      %(  </span>\n</li>))
  end

  def involvement_chip(room : Room, membership : Membership) : ERB::SafeString
    current = membership.involvement.to_s.presence || "mentions"
    nxt = next_involvement(room, current)
    dom_id = room.dom_id # rooms_<sti>_<id> (model_name.param_key)
    label = ChatLayout::INVOLVEMENT_LABELS[current]? || current
    ERB::SafeString.new(
      %(<turbo-frame id="involvement_#{dom_id}">\n) +
      %(<form action="/rooms/#{room.id.not_nil!}/involvement?involvement=#{nxt}" class="button_to" method="post">) +
      %(<input name="_method" type="hidden" value="put">) +
      %(<button aria-checked="true" aria-labelledby="involvement_label_#{dom_id}" ) +
      %(class="btn #{current}" role="checkbox" tabindex="0" type="submit">) +
      ChatLayout.icon("notification-bell-#{current}.svg") +
      %(<span class="for-screen-reader" id="involvement_label_#{dom_id}">) +
      %(#{HTML.escape(label)}</span></button></form>\n</turbo-frame>))
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

  def profile_nav : String
    String.build do |io|
      io << ChatLayout.nav_back("/") << "\n"
      io << %(<div class="flex-item-justify-end">\n)
      io << %(<form accept-charset="UTF-8" action="/session" data-controller="sessions" method="post"><input name="_method" type="hidden" value="delete">\n)
      io << %(<input data-sessions-target="pushSubscriptionEndpoint" id="push_subscription_endpoint" name="push_subscription_endpoint" type="hidden">\n)
      io << %(<button class="btn" data-action="sessions#logout:prevent">\n)
      io << ChatLayout.icon("logout.svg", nil) << "\n"
      io << %(<span class="for-screen-reader">Log out</span>\n</button>\n)
      io << %(</form>  </div>)
    end
  end
end
