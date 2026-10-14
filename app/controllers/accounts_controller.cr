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
    account.updated_at = Time.utc
    account.save!
    redirect_to "/account/edit"
  end

  private def page(io, account : Account, user : User) : Nil
    io << ChatLayout.head("Account settings", user, nil, chat: false)
    io << %(<body class="account">\n<main id="main-content">\n)
    io << %(<section class="panel txt-align-center flex flex-column gap">\n)
    if user.role == 1
      io << %(<form class="flex flex-column gap" action="/account" accept-charset="UTF-8" method="post">)
      io << %(<input type="hidden" name="_method" value="patch">)
      io << %(<div class="flex align-center gap">)
      io << %(<label class="flex align-center gap flex-item-grow">)
      io << %(<input name="account[name]" value=") << HTML.escape(account.name.to_s)
      io << %(" id="account_name" class="input txt-large" autocomplete="off" )
      io << %(placeholder="Name this account" autofocus></label>\n)
      io << %(<button class="btn btn--reversed center" type="submit">)
      io << %(<span class="for-screen-reader">Save changes</span></button>\n)
      io << %(</div></form>\n)
    else
      io << %(<h1 class="flex-item-grow txt-x-large">) << HTML.escape(account.name.to_s) << %(</h1>\n)
    end

    # Invite-блок (invite.eta): ссылка /join/<code> + QR + копирование.
    join_url = origin + "/join/" + account.join_code.to_s
    io << %(<div class="margin-block pad-inline pad-block-start fill-shade border-radius">)
    io << %(<div class="flex flex-column align-center gap">)
    io << %(<label class="flex flex-column gap full-width" style="--row-gap: 0.5em">)
    io << %(<strong id="invite_label" class="invite-label">Share to invite more people</strong>\n)
    io << %(<span class="flex align-center gap input input--actor fill-white">)
    io << %(<input type="text" class="input" id="invite_url" value=") << HTML.escape(join_url)
    io << %(" aria-labelledby="invite_label" readonly></span></label>\n)
    io << %(<div class="flex align-center gap">)
    qr_path = "/qr_code/" + Base64.urlsafe_encode(join_url, padding: false)
    io << %(<a href=") << HTML.escape(qr_path) << %(" class="btn">)
    io << %(<span class="for-screen-reader">Show join link QR code</span></a>\n)
    io << %(</div></div></div>\n)
    io << %(</section>\n</main>\n</body>\n</html>\n)
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
