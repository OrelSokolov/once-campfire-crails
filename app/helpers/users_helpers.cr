# UsersHelpers — ERB-хелперы app/views/users/show.html.erb:
# head+nav профиля юзера, transfer-ссылка (админ).
# Включается в UsersController; общий icon/page_close — ViewHelpers.
module UsersHelpers
  # head + body + nav (назад + «Edit my profile» для себя) + main.
  def page_open(viewer : User, subject : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("user", subject.name.to_s, viewer,
      nav_html: user_nav(viewer, subject)))
  end

  # layout_start (Screen "user"): назад + «Edit my profile» для себя.
  def user_nav(viewer : User, subject : User) : String
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
  def transfer_link(subject : User) : ERB::SafeString
    url = origin + "/session/transfers/" +
          generate_signed_id(subject.id.not_nil!, "user/transfer",
            expires_at: Time.utc + 4.hours)
    qr = "/qr_code/" + Base64.urlsafe_encode(url, padding: false)
    ERB::SafeString.new(
      %(<fieldset><legend class="gap">) +
      ChatLayout.icon("laptop.svg", 36, "colorize--black") +
      ChatLayout.icon("transfer.svg", 36, "colorize--black") +
      ChatLayout.icon("mobile-phone.svg", 36, "colorize--black") +
      %(</legend><div class="flex flex-column gap">) +
      %(<div class="flex align-center gap justify-center">) +
      ChatLayout.icon("crown.svg", 16, "flex-item-no-shrink colorize--black") +
      %(<label for="session_transfer_url">Share to get them back into their account</label></div>) +
      %(<input type="text" class="input" value=") + HTML.escape(url) +
      %(" id="session_transfer_url" readonly>) +
      %(<div class="flex align-center center gap">) +
      %(<a href=") + HTML.escape(qr) + %(" class="btn" data-lightbox-target="image" ) +
      %(data-action="lightbox#open" data-lightbox-url-value=") + HTML.escape(qr) + %(">) +
      ChatLayout.icon("qr-code.svg", 20, "colorize--black") + %(</a>) +
      ChatLayout.copy_button(url, "Copy auto-login link", "flex-item-no-shrink colorize--black") +
      %(</div></div></fieldset>))
  end
end
