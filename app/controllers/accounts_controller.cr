# GET/PATCH /account(/edit) — настройки аккаунта (референс:
# campfire-express routes.js /account + account.eta): имя, настройка
# создания комнат, invite-ссылка. Только администратор (role=1).
# Файл идёт первым по алфавиту в app/controllers/** — ApplicationController
# нужно потребовать явно.
require "./application_controller"

class AccountsController < ApplicationController
  def edit
    account = Account.take.not_nil!
    user = current_user.not_nil!
    render(html: String.build { |io| page(io, account, user) })
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    return render(plain: "forbidden", status: 403) unless user.role == 1
    account = Account.take.not_nil!
    account.name = nested("name") unless nested?("name").nil?
    # restrict_room_creation_to_administrators (settings JSON, PUT-свитч)
    settings = params["account"]?
    if settings.is_a?(ActionController::Parameters) &&
       (nest = settings["settings"]?).is_a?(ActionController::Parameters) &&
       (restrict = nest["restrict_room_creation_to_administrators"]?)
      value = restrict.to_s == "true"
      existing = account.settings.try(&.to_json).presence
      new_json = if existing.nil? || existing == "{}"
        %({"restrict_room_creation_to_administrators":#{value}})
      elsif existing.includes?("restrict_room_creation_to_administrators")
        existing.gsub(/"restrict_room_creation_to_administrators"\s*:\s*(true|false)/,
          %("restrict_room_creation_to_administrators":#{value}))
      else
        existing.sub(%r(\s*\}\s*\z), %(", "restrict_room_creation_to_administrators":#{value}}))
      end
      account.settings = JSON::Any.from_json(new_json)
    end
    account.updated_at = Time.utc
    account.save!
    redirect_to "/account/edit"
  end

  # account.eta + account_nav.eta + invite.eta: nav (боты/кастомные
  # стили для админа), имя с check-иконкой, restrict-свитч, invite-блок
  # (person-add/qr-code/copy-paste), список юзеров, версия в футере.
  private def page(io, account : Account, user : User) : Nil
    version = HTML.escape(ENV["APP_VERSION"]? || "parity")
    version_footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">) + version + %(</span></div>)
    io << ChatLayout.page_open("account", "Account settings", user,
      nav_html: account_nav(user))
    io << %(<section class="panel txt-align-center flex flex-column gap" style="view-transition-name: account-settings">\n)
    if user.role == 1
      io << %(<form class="flex flex-column gap" action="/account" accept-charset="UTF-8" method="post">)
      io << %(<input type="hidden" name="_method" value="patch">)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow">)
      io << %(<input name="account[name]" value=") << HTML.escape(account.name.to_s)
      io << %(" id="account_name" class="input txt-large" autocomplete="off" )
      io << %(placeholder="Name this account" autofocus></label>\n)
      io << %(<button class="btn btn--reversed center" type="submit">)
      io << ChatLayout.icon("check.svg")
      io << %(<span class="for-screen-reader">Save changes</span></button>\n)
      io << %(</div></form>\n)
      # restrict_room_creation_to_administrators (settings JSON)
      restrict = account.settings.to_s.includes?(%("restrict_room_creation_to_administrators":true))
      io << %(<div class="margin-block-start pad-block pad-inline-double fill-shade border-radius">)
      io << %(<form class="flex align-center gap center" method="post" action="/account">)
      io << %(<input type="hidden" name="_method" value="put">)
      io << %(<div class="flex-item-grow flex align-center gap txt-align-start">)
      io << ChatLayout.icon("crown.svg", 18, "colorize--black")
      io << %( Must be admin to create new rooms</div>)
      io << %(<input type="hidden" name="account[settings][restrict_room_creation_to_administrators]" )
      io << %(value=") << (restrict ? "false" : "true") << %(">)
      io << %(<label class="switch"><input type="checkbox" class="switch__input")
      io << %( checked) if restrict
      io << %( data-action="change->form#submit"><span class="switch__btn round"></span>)
      io << %(<span class="for-screen-reader">Must be admin to create new rooms</span></label></form></div>\n)
    else
      io << %(<figure class="account-logo avatar txt-xx-large center">)
      io << %(<img src=") << ChatLayout.asset("logos/app-icon.png") << %(" alt="Account logo" width="300" height="300"></figure>\n)
      io << %(<h1 class="flex-item-grow txt-x-large">) << HTML.escape(account.name.to_s) << %(</h1>\n)
    end

    # Invite-блок (invite.eta): person-add в поле, QR + копирование.
    join_url = origin + "/join/" + account.join_code.to_s
    qr_path = "/qr_code/" + Base64.urlsafe_encode(join_url, padding: false)
    io << %(<div class="margin-block pad-inline pad-block-start fill-shade border-radius">)
    io << %(<div class="flex flex-column align-center gap">)
    io << %(<label class="flex flex-column gap full-width" style="--row-gap: 0.5em">)
    io << %(<strong id="invite_label" class="invite-label">Share to invite more people</strong>\n)
    io << %(<span class="flex align-center gap input input--actor fill-white">)
    io << ChatLayout.icon("person-add.svg", 20, "colorize--black")
    io << %(<input type="text" class="input" id="invite_url" value=") << HTML.escape(join_url)
    io << %(" aria-labelledby="invite_label" readonly></span></label>\n)
    io << %(<div class="flex align-center gap">)
    io << %(<a href=") << HTML.escape(qr_path) << %(" class="btn" data-lightbox-target="image" )
    io << %(data-action="lightbox#open" data-lightbox-url-value=") << HTML.escape(qr_path) << %(">)
    io << %(<span class="for-screen-reader">Show join link QR code</span>)
    io << ChatLayout.icon("qr-code.svg", 20, "colorize--black") << %(</a>\n)
    io << ChatLayout.copy_button(join_url, "Copy join link") << %(\n)
    io << %(</div></div>\n)

    # Список пользователей аккаунта (account_administrators/account_users)
    io << %(<hr class="margin-block separator full-width" style="--border-style: solid">)
    io << %(<menu class="flex flex-column gap margin-none pad">\n)
    User.where("status = 0").order("id").each do |u|
      admin = u.role == 1
      io << %(<li class="flex align-center gap margin-none min-width">)
      io << %(<figure class="avatar flex-item-no-shrink" style="--avatar-size: 4ch">)
      io << %(<a title=") << HTML.escape(u.name.to_s)
      io << %(" class="btn avatar" data-turbo-frame="_top" href="/users/) << u.id.not_nil! << %(">)
      io << %(<img aria-hidden="true" loading="lazy" src="/users/) << u.id.not_nil! << %(/avatar" width="48" height="48"></a></figure>)
      io << %(<div class="min-width"><div class="overflow-ellipsis fill-shade"><strong>)
      io << HTML.escape(u.name.to_s) << %(</strong></div></div>)
      io << ChatLayout.icon("crown.svg", 16, "flex-item-no-shrink colorize--black") if admin
      io << %(</li>\n)
    end
    io << %(</menu></div>\n)
    io << %(</section>\n)
    io << ChatLayout.page_close(version_footer)
  end

  # account_nav.eta: назад + ссылки на ботов/кастомные стили (админ).
  private def account_nav(user : User) : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      if user.role == 1
        io << %(<div class="flex align-center gap flex-item-justify-end">)
        io << %(<a href="/account/bots" class="btn" style="view-transition-name: chat-bots">)
        io << ChatLayout.icon("bot.svg") << %(<span class="for-screen-reader">Set up chat bots</span></a>)
        io << %(<a href="/account/custom_styles/edit" class="btn" style="view-transition-name: custom-styles">)
        io << ChatLayout.icon("art.svg") << %(<span class="for-screen-reader">Custom styles</span></a>)
        io << %(</div>)
      end
    end
  end

  private def nested?(key : String) : String?
    nested = params["account"]?
    return nil unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? nil : value.to_s
  end

  private def nested(key : String) : String
    nested?(key).to_s
  end
end
