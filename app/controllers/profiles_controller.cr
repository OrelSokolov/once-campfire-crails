# GET/PATCH /users/me/profile — профиль текущего пользователя
# (референс: campfire-express routes.js /users/me/profile + profile.eta):
# форма name/email/password/bio, список комнат участия и session
# transfer-ссылка с QR (4 часа действия, purpose "user/transfer").
class ProfilesController < ApplicationController
  def show
    user = current_user.not_nil!
    render(html: String.build { |io| page(io, user) })
  end

  def update
    Campfire::PageCache.invalidate! # write: сброс whole-page кэша
    user = current_user.not_nil!
    user.name = nested("name") unless nested?("name").nil?
    user.email_address = nested("email_address") unless nested?("email_address").nil?
    user.bio = nested("bio") unless nested?("bio").nil?
    password = nested?("password").to_s
    unless password.empty?
      user.password_digest = Crypto::Bcrypt::Password.create(password, cost: 10).to_s
    end
    user.updated_at = Time.utc
    user.save!
    redirect_to "/users/me/profile"
  end

  # profile.eta: nav (back + logout), аватар-блок (camera), поля с
  # иконками person/email/password/bio, save с check, список комнат с
  # involvement-колокольчиками, transfer_link (QR/copy иконки).
  private def page(io, user : User) : Nil
    io << ChatLayout.page_open("profile", "Profile: #{user.name}", user,
      nav_html: profile_nav)
    io << %(<section class="panel flex flex-column gap" style="view-transition-name: avatar-#{user.id.not_nil!}">\n)

    # Аватар (загрузка файла не поддерживается — без runtime-ошибок)
    io << %(<div class="align-center center avatar__form gap">\n)
    io << %(<form class="txt-medium" enctype="multipart/form-data" action="/users/me/profile" method="post">)
    io << %(<input type="hidden" name="_method" value="patch">)
    io << %(<label class="btn input--file">) << ChatLayout.icon("camera.svg")
    io << %(<input type="file" name="user[avatar]" id="file" class="input" accept="image/*">)
    io << %(<span class="for-screen-reader">Upload avatar</span></label></form>\n)
    io << %(<form enctype="multipart/form-data" action="/users/me/profile" method="post">)
    io << %(<input type="hidden" name="_method" value="patch">)
    io << %(<label class="btn avatar input--file txt-xx-large">)
    io << %(<img src="/users/#{user.id.not_nil!}/avatar" aria-hidden="true" width="300" height="300">)
    io << %(<input type="file" name="user[avatar]" id="file" class="input" accept="image/*">)
    io << %(<span class="for-screen-reader">Avatar</span></label></form>\n)
    io << %(</div>\n)

    io << %(<form action="/users/me/profile" accept-charset="UTF-8" method="post">)
    io << %(<input type="hidden" name="_method" value="patch">)
    io << %(<div class="flex flex-column gap">\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input name="user[name]" id="user_name" value=") << HTML.escape(user.name.to_s)
    io << %(" class="input txt-large" autocomplete="name" placeholder="Enter your name" autofocus required data-1p-ignore="true">)
    io << ChatLayout.icon("person.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input type="email" name="user[email_address]" id="user_email_address" value=") << HTML.escape(user.email_address.to_s)
    io << %(" class="input txt-large" autocomplete="username" placeholder="Enter your email address">)
    io << ChatLayout.icon("email.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input type="password" name="user[password]" id="user_password" class="input txt-large" )
    io << %(autocomplete="new-password" placeholder="Change password" maxlength="72">)
    io << ChatLayout.icon("password.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<div class="flex align-start gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<textarea name="user[bio]" id="user_bio" class="input txt-large" )
    io << %(placeholder="A few words about yourself…" maxlength="200" rows="3">)
    io << HTML.escape(user.bio.to_s) << %(</textarea>)
    io << ChatLayout.icon("bio.svg", 24, "colorize--black") << %(</label></div>\n)
    io << %(<button class="btn btn--reversed center txt-large" type="submit">)
    io << ChatLayout.icon("check.svg") << %(<span class="for-screen-reader">Save changes</span></button>\n)
    io << %(</div></form>\n)

    # Комнаты участия (эталон: menu с Memberships + DirectMemberships,
    # involvement-колокольчик на каждую).
    rooms = Room.where(
      %(id IN (SELECT room_id FROM memberships WHERE user_id = ?)), user.id.not_nil!)
      .to_a.index_by(&.id.not_nil!)
    io << %(<div class="margin-block pad-inline pad-block fill-shade border-radius">)
    io << %(<menu class="flex flex-column gap margin-none pad">\n)
    user.memberships.each do |membership|
      room = rooms[membership.room_id.not_nil!]?
      next unless room
      io << %(<li class="flex align-center gap margin-none min-width membership-item">)
      io << %(<a href="/rooms/) << room.id.not_nil!.to_s << %(" class="overflow-ellipsis fill-shade txt-primary txt-undecorated"><strong>)
      label = room.name.to_s.presence || "Direct message"
      io << HTML.escape(label) << %(</strong></a><hr class="separator" aria-hidden="true">)
      io << %(<span class="txt-small">) << involvement_chip(room, membership) << %(</span></li>\n)
    end
    io << %(</menu></div>\n)

    # Session transfer (transfer_link.eta): laptop/transfer/mobile иконки,
    # ссылка + QR + копирование.
    transfer_url = transfer_url_for(user)
    qr_path = "/qr_code/" + Base64.urlsafe_encode(transfer_url, padding: false)
    io << %(<fieldset><legend class="gap">)
    io << ChatLayout.icon("laptop.svg", 36, "colorize--black")
    io << ChatLayout.icon("transfer.svg", 36, "colorize--black")
    io << ChatLayout.icon("mobile-phone.svg", 36, "colorize--black")
    io << %(</legend>)
    io << %(<div class="flex flex-column gap">)
    io << %(<label for="session_transfer_url" class="for-screen-reader">)
    io << %(Use this link to login automatically on another device</label>\n)
    io << %(<input type="text" class="input" value=") << HTML.escape(transfer_url)
    io << %(" id="session_transfer_url" readonly>\n)
    io << %(<div class="flex align-center center gap">)
    io << %(<a href=") << HTML.escape(qr_path) << %(" class="btn" data-lightbox-target="image" )
    io << %(data-action="lightbox#open" data-lightbox-url-value=") << HTML.escape(qr_path) << %(">)
    io << %(<span class="for-screen-reader">Show auto-login QR code</span>)
    io << ChatLayout.icon("qr-code.svg", 20, "colorize--black") << %(</a>\n)
    io << ChatLayout.copy_button(transfer_url, "Copy auto-login link") << %(\n)
    io << %(</div></div></fieldset>\n)
    io << %(</section>\n)
    io << ChatLayout.page_close
  end

  # profile_nav.eta: назад + logout (кнопка-иконка, форма на /session).
  private def profile_nav : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      io << %(<div class="flex-item-justify-end"><form method="post" action="/session">)
      io << %(<input type="hidden" name="_method" value="delete">)
      io << %(<button class="btn">) << ChatLayout.icon("logout.svg")
      io << %(<span class="for-screen-reader">Log out</span></button></form></div>)
    end
  end

  # involvement.eta (статически, без involvement-роута).
  private def involvement_chip(room : Room, membership : Membership) : String
    involvement = membership.involvement.to_s.presence || "mentions"
    human = ChatLayout::INVOLVEMENT_LABELS[involvement]? || involvement
    %(<turbo-frame id="involvement_room_#{room.id.not_nil!}">) +
      %(<button role="checkbox" aria-checked="true" tabindex="0" class="btn #{involvement}" type="button">) +
      ChatLayout.icon("notification-bell-#{involvement}.svg") +
      %(<span class="for-screen-reader">) + human + %(</span></button></turbo-frame>)
  end

  # 4 часа действия, как в референсе (routes.js: 4 * 3600000).
  private def transfer_url_for(user : User) : String
    origin + "/session/transfers/" +
      generate_signed_id(user.id.not_nil!, "user/transfer",
        expires_at: Time.utc + 4.hours)
  end

  private def nested?(key : String) : String?
    nested = params["user"]?
    return nil unless nested.is_a?(ActionController::Parameters)
    value = nested[key]?
    value.nil? ? nil : value.to_s
  end

  private def nested(key : String) : String
    nested?(key).to_s
  end
end
