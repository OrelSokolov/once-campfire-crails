# AccountsHelpers — ERB-хелперы app/views/accounts/edit.html.erb:
# head+nav аккаунта, футер с версией, кнопка копирования invite-ссылки.
# Включается в AccountsController; общий icon/page_close — ViewHelpers.
module AccountsHelpers
  # head + body + nav аккаунта (боты/кастомные стили для админа) + main.
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("account", "Account settings", user,
      nav_html: account_nav(user)))
  end

  # layouts/_body_close + версия в футере (Campfire™ version badge).
  def page_close : ERB::SafeString
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">) +
             version + %(</span></div>)
    ERB::SafeString.new(ChatLayout.page_close(footer))
  end

  def copy_button(url : String) : ERB::SafeString
    # _invite.html.erb: span первой, img с colorize--black
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy join link", "colorize--black"))
  end

  # translation_button (translations_helper): details/popup меню переводов
  # для подписей формы аккаунта (account_name).
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end

  # fresh_account_logo_path (accounts/edit: превью 48px, не-админ ветка
  # 300px, кнопка удаления) — /account/logo с cache-buster по updated_at.
  def logo_src : String
    ChatLayout.fresh_account_logo_path(@account)
  end

  # Строка юзера в списке accounts/edit — партиал
  # accounts/users/_user.html.erb (порт _users/_user.html.erb): аватар,
  # тумблер роли (check_box), удаление (button_to), «My settings».

  # account_nav.eta → accounts/_nav.html.erb: назад
  # (link_back_to_last_room_visited) + ссылки на боты/кастомные стили
  # (админ). Ссылки — литеральные <a>: link_to из action_view_cr ставит
  # href последним атрибутом, а вывод порта (account_nav.eta) — href
  # первым, byte-parity важнее.
  def account_nav(user : User) : String
    render(partial: "accounts/nav", locals: {"user" => user}).raw
  end

  # TrackedRoomVisit (rooms_helper): link_back_to_last_room_visited —
  # cookie last_room (если комната видима пользователю), иначе
  # original-комната; корень — когда видимых комнат нет.
  private def last_room_visited_path(user : User) : String
    room = nil
    if last = cookies["last_room"]?
      room = Room.visible_for(user).where("id = ?", last.to_i64?).take
    end
    room ||= Room.visible_for(user).order("id").first?
    room ? room_path(room.id.not_nil!) : root_path
  end
end
