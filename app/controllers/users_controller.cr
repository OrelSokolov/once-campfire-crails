# GET /users/:id — публичный профиль пользователя (user.eta): аватар,
# имя/bio/email (админу), кнопка Ping (POST /rooms/directs?user_ids[]=),
# transfer-ссылка (админ, transfer_link.eta). Бан не портирован (нет роута).
class UsersController < ApplicationController
  def show
    viewer = current_user.not_nil!
    id = params["id"].to_s.to_i64?
    subject = id ? User.find?(id) : nil
    unless subject
      response.status = :not_found
      return render(plain: "User not found")
    end

    response.headers["Content-Type"] = "text/html; charset=utf-8"
    render(html: String.build do |io|
      io << ChatLayout.page_open("user", subject.name.to_s, viewer,
        nav_html: user_nav(viewer, subject))
      io << %(<section class="panel txt-align-center">)
      io << %(<div class="flex flex-column gap)
      io << %( banned) if subject.status == 2
      io << %("><div class="avatar txt-xx-large center" style="background: white">)
      io << %(<img src="/users/) << subject.id.not_nil! << %(/avatar" alt="Profile avatar" class="avatar"></div>\n)
      if subject.role == 2
        io << %(<div class="pad-double--inline push--inline push--block-start">)
        if subject.status == 0
          io << %(<form class="button_to" method="post" action="/rooms/directs?user_ids%5B%5D=)
          io << subject.id.not_nil! << %("><button class="btn btn--primary full-width txt--large">)
          io << ChatLayout.icon("messages.svg") << %(</button></form>)
        else
          io << %(<div>) << HTML.escape(subject.name.to_s) << %( is no longer on this account</div>)
        end
        io << %(</div>)
      elsif subject.status == 1
        io << %(<div><h1 class="txt-x-large margin-none">) << HTML.escape(subject.name.to_s)
        io << %(</h1><div>) << HTML.escape(subject.name.to_s) << %( is no longer on this account</div></div>)
      else
        io << %(<div class="flex flex-column gap" style="--row-gap: calc(var(--block-space) / 3)">)
        io << %(<h1 class="txt-x-large txt-tight-lines margin-none">) << HTML.escape(subject.name.to_s) << %(</h1>)
        if viewer.role == 1 && subject.role != 2
          io << %(<div><a href="mailto:) << HTML.escape(subject.email_address.to_s) << %(">)
          io << HTML.escape(subject.email_address.to_s) << %(</a></div>)
        end
        io << %(<div>) << HTML.escape(subject.bio.to_s) << %(</div></div>\n)
        if subject.status == 0
          io << %(<div class="pad-inline-double margin-inline margin-block-start">)
          io << %(<form method="post" action="/rooms/directs?user_ids%5B%5D=)
          io << subject.id.not_nil! << %("><button class="btn btn--reversed full-width txt-large">)
          io << ChatLayout.icon("messages.svg")
          io << %( aria-label="Ping ) << HTML.escape(subject.name.to_s) << %("></button></form></div>\n)
          if viewer.role == 1 && viewer.id != subject.id
            io << %(<hr class="margin-block-start borderless">)
            io << transfer_link(io, subject)
          end
        end
      end
      io << %(</div></section>\n)
      io << ChatLayout.page_close
    end)
  end

  # layout_start (Screen "user"): назад + «Edit my profile» для себя.
  private def user_nav(viewer : User, subject : User) : String
    String.build do |io|
      io << ChatLayout.nav_back("/")
      if viewer.id == subject.id
        io << %(<div class="flex align-center gap flex-item-justify-end">)
        io << %(<a href="/users/me/profile" class="btn">)
        io << ChatLayout.icon("pencil.svg")
        io << %(<span class="for-screen-reader">Edit my profile</span></a></div>)
      end
    end
  end

  # transfer_link.eta (админский блок на профиле юзера).
  private def transfer_link(io, subject : User) : Nil
    url = origin + "/session/transfers/" +
      generate_signed_id(subject.id.not_nil!, "user/transfer",
        expires_at: Time.utc + 4.hours)
    qr = "/qr_code/" + Base64.urlsafe_encode(url, padding: false)
    io << %(<fieldset><legend class="gap">)
    io << ChatLayout.icon("laptop.svg", 36, "colorize--black")
    io << ChatLayout.icon("transfer.svg", 36, "colorize--black")
    io << ChatLayout.icon("mobile-phone.svg", 36, "colorize--black")
    io << %(</legend><div class="flex flex-column gap">)
    io << %(<div class="flex align-center gap justify-center">)
    io << ChatLayout.icon("crown.svg", 16, "flex-item-no-shrink colorize--black")
    io << %(<label for="session_transfer_url">Share to get them back into their account</label></div>)
    io << %(<input type="text" class="input" value=") << HTML.escape(url)
    io << %(" id="session_transfer_url" readonly>)
    io << %(<div class="flex align-center center gap">)
    io << %(<a href=") << HTML.escape(qr) << %(" class="btn" data-lightbox-target="image" )
    io << %(data-action="lightbox#open" data-lightbox-url-value=") << HTML.escape(qr) << %(">)
    io << ChatLayout.icon("qr-code.svg", 20, "colorize--black") << %(</a>)
    io << ChatLayout.copy_button(url, "Copy auto-login link")
    io << %(</div></div></fieldset>)
  end
end
