# UsersHelpers — ERB-хелперы app/views/users/show.html.erb:
# head+nav профиля юзера, transfer-ссылка (админ).
# Включается в UsersController; общий icon/page_close — ViewHelpers.
module UsersHelpers
  # head + body + nav (назад + «Edit my profile» для себя) + main.
  def page_open(viewer : User, subject : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("user", subject.name.to_s,
      nav_html: user_nav(viewer, subject)))
  end

  # layout_start (Screen "user") → users/_nav.html.erb: назад +
  # «Edit my profile» для себя, у чужого профиля — пустой блок справа
  # (артефакты profile-jason). Ссылка — литеральный <a>: link_to из
  # action_view_cr ставит href последним, вывод порта — href первым.
  def user_nav(viewer : User, subject : User) : String
    render(partial: "users/nav", locals: {"viewer" => viewer, "subject" => subject}).raw
  end

  # transfer_link.eta (админский блок на профиле юзера): QR/копирование/
  # web-share той же разметки, что и собственный профиль (users/profiles).
  def transfer_link(subject : User) : ERB::SafeString
    url = origin + "/session/transfers/" +
          generate_signed_id(subject.id.not_nil!, "user/transfer",
            expires_at: Time.utc + 4.hours)
    qr = "/qr_code/" + Base64.urlsafe_encode(url, padding: false)
    ERB::SafeString.new(
      %(<fieldset>\n<legend class="gap">\n) +
      ChatLayout.icon("laptop.svg", 36, "colorize--black") + "\n" +
      ChatLayout.icon("transfer.svg", 36, "colorize--black") + "\n" +
      ChatLayout.icon("mobile-phone.svg", 36, "colorize--black") + "\n" +
      %(</legend>\n<div class="flex flex-column gap">\n) +
      %(<div class="flex align-center gap justify-center">\n) +
      ChatLayout.icon("crown.svg", 16, "flex-item-no-shrink colorize--black") + "\n" +
      %(<label for="session_transfer_url">Share to get them back into their account</label>\n</div>\n) +
      %(<input class="input" id="session_transfer_url" readonly="" type="text" value=") +
      HTML.escape(url) + %(">\n) +
      %(<div class="flex align-center center gap">\n) +
      %(<a class="btn" data-action="lightbox#open" data-lightbox-target="image" ) +
      %(data-lightbox-url-value=") + HTML.escape(qr) + %(" href=") + HTML.escape(qr) + %(">\n) +
      %(<span class="for-screen-reader">Show auto-login QR code</span>\n) +
      ChatLayout.icon("qr-code.svg", 20, "colorize--black") + "\n</a>\n" +
      ChatLayout.copy_button(url, "Copy auto-login link",
        icon_class: "flex-item-no-shrink colorize--black") + "\n" +
      ChatLayout.web_share_button(url) +
      %(\n</div>\n</div>\n</fieldset>))
  end
end
