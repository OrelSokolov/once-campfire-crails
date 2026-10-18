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

  # Строка юзера в списке accounts/edit (порт _users/_user.html.erb):
  # аватар по токен-путю с title «имя — био», сепаратор, тумблер роли
  # (crown-form PATCH /account/users/:id, disabled у себя), удаление
  # (minus DELETE, turbo-confirm) и «My settings» для себя. banned —
  # класс глухой строки; кнопки только у active-строк.
  def account_user_row(u : User) : ERB::SafeString
    viewer = @user.not_nil!
    admin = viewer.role == 1
    uid = u.id.not_nil!
    name = HTML.escape(u.name.to_s)
    banned = u.status == 2
    li_closed = false
    html = String.build do |io|
      io << %(<li class="flex align-center gap margin-none#{banned ? " banned" : " "}">\n)
      io << %(<figure class="avatar flex-item-no-shrink" style="--avatar-size: 3.75ch;">\n)
      io << ChatLayout.avatar_link(u, "lazy") << %(\n</figure>\n)
      io << %(<div class="min-width">\n<div class="overflow-ellipsis fill-shade"><strong>) << name
      io << %(</strong></div>\n</div>\n<hr class="separator" aria-hidden="true">\n)
      if admin && !banned && u.status == 0
        unless u.role == 2
          administrator = u.role == 1
          disabled = uid == viewer.id
          dis = disabled ? %( disabled="disabled") : ""
          io << %(<form accept-charset="UTF-8" action="/account/users/#{uid}" data-controller="form" method="post"><input type="hidden" name="_method" value="patch">\n)
          io << %(<label class="btn txt-small flex-item-no-shrink" for="role_user_#{uid}">\n)
          io << %(<span class="for-screen-reader">Role: ) << (administrator ? "Administrator" : "Member") << %(</span>\n)
          io << ChatLayout.icon("crown.svg") << %(\n)
          io << %(<input type="hidden" name="user[role]" value="member"#{dis}><input type="checkbox" name="user[role]" value="administrator" id="role_user_#{uid}" hidden="hidden" data-action="form#submit"#{administrator ? %( checked="checked") : ""}#{dis}>\n)
          io << %(</label>\n</form>\n)
        end
        if uid != viewer.id
          io << %(<form action="/account/users/#{uid}" class="button_to" method="post"><input type="hidden" name="_method" value="delete"><button class="btn txt-small flex-item-no-shrink btn--negative" data-turbo-confirm="Are you sure you want to permanently remove this person from the account? This can’t be undone." type="submit">\n)
          io << ChatLayout.icon("minus.svg") << %(\n)
          io << %(<span class="for-screen-reader">Delete ) << name << %(</span>\n</button></form></li>\n)
          li_closed = true
        end
      end
      if uid == viewer.id
        io << %(<a class="btn txt-small flex-item-no-shrink" href="/users/me/profile" target="_top">\n)
        io << ChatLayout.icon("pencil.svg") << %(\n)
        io << %(<span class="for-screen-reader">My settings</span>\n</a></li>\n)
        li_closed = true
      end
      # Строка без кнопок (banned/не-админ смотрящий): </li> без переноса.
      io << %(</li>\n) unless li_closed
    end
    ERB::SafeString.new(html)
  end

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
    room ? "/rooms/#{room.id.not_nil!}" : "/"
  end
end
