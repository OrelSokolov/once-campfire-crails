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

  private def page(io, user : User) : Nil
    io << ChatLayout.head("Profile: #{user.name}", user, nil, chat: false)
    io << %(<body class="profile">\n<main id="main-content">\n)
    io << %(<section class="panel flex flex-column gap">\n)
    io << %(<form action="/users/me/profile" accept-charset="UTF-8" method="post">)
    io << %(<input type="hidden" name="_method" value="patch">)
    io << %(<div class="flex flex-column gap">\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input name="user[name]" id="user_name" value=") << HTML.escape(user.name.to_s)
    io << %(" class="input txt-large" autocomplete="name" placeholder="Enter your name" autofocus required data-1p-ignore="true"></label></div>\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input type="email" name="user[email_address]" id="user_email_address" value=") << HTML.escape(user.email_address.to_s)
    io << %(" class="input txt-large" autocomplete="username" placeholder="Enter your email address"></label></div>\n)
    io << %(<div class="flex align-center gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<input type="password" name="user[password]" id="user_password" class="input txt-large" )
    io << %(autocomplete="new-password" placeholder="Change password" maxlength="72"></label></div>\n)
    io << %(<div class="flex align-start gap"><label class="flex align-center gap flex-item-grow input input--actor">)
    io << %(<textarea name="user[bio]" id="user_bio" class="input txt-large" )
    io << %(placeholder="A few words about yourself…" maxlength="200" rows="3">)
    io << HTML.escape(user.bio.to_s) << %(</textarea></label></div>\n)
    io << %(<button class="btn btn--reversed center txt-large" type="submit">)
    io << %(<span class="for-screen-reader">Save changes</span></button>\n)
    io << %(</div></form>\n)

    # Комнаты участия (эталон: menu с Memberships + DirectMemberships).
    io << %(<div class="margin-block pad-inline pad-block fill-shade border-radius">)
    io << %(<menu class="flex flex-column gap margin-none pad">\n)
    user.memberships.each do |membership|
      room = Room.find?(membership.room_id.not_nil!)
      next unless room
      io << %(<li class="flex align-center gap margin-none min-width membership-item">)
      io << %(<a href="/rooms/) << room.id.not_nil!.to_s << %(" class="overflow-ellipsis fill-shade txt-primary txt-undecorated"><strong>)
      io << HTML.escape(room.name.to_s) << %(</strong></a></li>\n)
    end
    io << %(</menu></div>\n)

    # Session transfer (transfer_link.eta): ссылка + QR + копирование.
    transfer_url = transfer_url_for(user)
    qr_path = "/qr_code/" + Base64.urlsafe_encode(transfer_url, padding: false)
    io << %(<fieldset><legend class="gap">Use this link to login automatically on another device</legend>)
    io << %(<div class="flex flex-column gap">)
    io << %(<label for="session_transfer_url" class="for-screen-reader">)
    io << %(Use this link to login automatically on another device</label>\n)
    io << %(<input type="text" class="input" value=") << HTML.escape(transfer_url)
    io << %(" id="session_transfer_url" readonly>\n)
    io << %(<div class="flex align-center center gap">)
    io << %(<a href=") << HTML.escape(qr_path) << %(" class="btn">)
    io << %(<span class="for-screen-reader">Show auto-login QR code</span></a>\n)
    io << %(<button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" )
    io << %(data-copy-to-clipboard-success-class="btn--success" )
    io << %(data-copy-to-clipboard-content-value=") << HTML.escape(transfer_url)
    io << %("><span class="for-screen-reader">Copy auto-login link</span></button>\n)
    io << %(</div></div></fieldset>\n)
    io << %(</section>\n</main>\n</body>\n</html>\n)
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
