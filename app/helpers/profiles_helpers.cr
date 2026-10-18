# ProfilesHelpers — ERB-хелперы app/views/users/profiles/show.html.erb:
# head+nav профиля, involvement-чипы со сменой уровня уведомлений,
# список комнат участия, transfer-блок. Включается в
# Users::ProfilesController; общий icon/page_close — ViewHelpers.
module ProfilesHelpers
  # SafeString: сырой HTML из ChatLayout без повторного экранирования
  # в <%= %> (как boosts).

  # head + body + nav профиля (back + logout) + main (ChatLayout.page_open).
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("profile", user.name.to_s, user,
      nav_html: profile_nav))
  end

  # rooms/involvements/_install_instructions.html.erb — pwa-диалог
  # (ChatERB-партиал, UA-классификация как у bell-тестов).
  def install_instructions : ERB::SafeString
    ChatERB.new(ua: @ua).render("install_instructions")
  end

  # translation_button (translations_helper) — SafeString для <%= %>.
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end

  # fresh_user_avatar_path (avatars_helper): токен-путь с cache-buster.
  def fresh_avatar_path(user : User) : String
    ChatLayout.fresh_user_avatar_path(user.id.not_nil!, user.updated_at)
  end

  # web-share (transfer_link.eta): делиться auto-login-ссылкой; кнопка
  # скрыта (hidden), показывается стимулусом при поддержке navigator.share.
  def web_share_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.web_share_button(url))
  end

  # copy_button: иконка copy-paste с классом flex-item-no-shrink (артефакты).
  def copy_button(url : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy auto-login link",
      icon_class: "flex-item-no-shrink colorize--black"))
  end

  # room_display_name(room, for_user:) RoomsHelper: обычные комнаты —
  # имя; direct (name NULL) — имена собеседников через to_sentence.
  def profile_display_name(room : Room, viewer : User) : String
    return room.name.to_s unless room.name.nil?
    others = User.where(
      %(id IN (SELECT user_id FROM memberships WHERE room_id = ? AND user_id != ?)),
      room.id.not_nil!, viewer.id.not_nil!)
      .order("id").map(&.name.to_s)
    ChatLayout.display_sentence(others, viewer.name.to_s)
  end

  # Строка списка участия (rooms/_membership.html.erb референса):
  # ссылка + разделитель + involvement-чип.
  def membership_row(room : Room, membership : Membership,
                     viewer : User) : ERB::SafeString
    name = HTML.escape(profile_display_name(room, viewer))
    ERB::SafeString.new(
      %(<li class="flex align-center gap margin-none min-width membership-item">\n) +
      %(<a class="overflow-ellipsis fill-shade txt-primary txt-undecorated" href="/rooms/#{room.id.not_nil!}">\n) +
      %(<strong>#{name}</strong>\n</a>\n) +
      %(<hr aria-hidden="true" class="separator">\n) +
      %(<span class="txt-small">\n) +
      involvement_chip(room, membership).raw +
      %(  </span>\n</li>))
  end

  # involvement.html.erb + InvolvementsHelper: пустой turbo-frame с
  # button_to-формой PUT /rooms/:id/involvement — клик циклически
  # переключает уровень уведомлений (следующий уровень в action-query).
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

  # Involvement#next референса: shared-комнаты проходят полный цикл
  # mentions→everything→nothing→invisible, direct — только
  # everything↔nothing (invisible в direct недоступен).
  private def next_involvement(room : Room, current : String) : String
    return current == "everything" ? "nothing" : "everything" if room.name.nil?
    case current
    when "mentions"   then "everything"
    when "everything" then "nothing"
    when "nothing"    then "invisible"
    else                   "mentions"
    end
  end

  # profile_nav: назад + logout (форма на /session с push-подпиской,
  # sessions#logout:prevent — layout_start.eta).
  def profile_nav : String
    String.build do |io|
      io << ChatLayout.nav_back("/") << "\n"
      io << %(<div class="flex-item-justify-end">\n)
      io << %(<form accept-charset="UTF-8" action="/session" data-controller="sessions" method="post"><input name="_method" type="hidden" value="delete">\n)
      io << %(<input data-sessions-target="pushSubscriptionEndpoint" id="push_subscription_endpoint" name="push_subscription_endpoint" type="hidden">\n)
      io << %(<button class="btn" data-action="sessions#logout:prevent">\n)
      io << ChatLayout.icon("logout.svg", nil)
      io << %(<span class="for-screen-reader">Log out</span>\n</button>\n)
      io << %(</form>  </div>)
    end
  end
end
