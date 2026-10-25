# ERB helpers for app/views/users/show.html.erb, included in UsersController.
module UsersHelper
  include ActionController::Helper
  def page_open(viewer : User, subject : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("user", subject.name.to_s,
      nav_html: user_nav(viewer, subject)))
  end

  # Oracle users_helper button_to_direct_room_with(user).
  def button_to_direct_room_with(user : User) : ERB::SafeString
    button_to "/rooms/directs?user_ids%5B%5D=#{user.id.not_nil!}",
      class: "btn btn--primary full-width txt--large" do
      icon("messages.svg")
    end
  end

  # users/_nav.html.erb: back link + "Edit my profile" for self.
  # Literal <a>: link_to from action_view_cr renders href last, oracle output has it first.
  def user_nav(viewer : User, subject : User) : String
    render(partial: "users/nav", locals: {"viewer" => viewer, "subject" => subject}).raw
  end

  # Admin transfer panel on the user profile: QR/copy/web-share of the auto-login URL.
  def transfer_link(subject : User) : ERB::SafeString
    url = origin + "/session/transfers/" +
          generate_signed_id(subject.id.not_nil!, "user/transfer",
            expires_at: Time.utc + 4.hours)
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
      link_to_zoom_qr_code(url) {
        ERB::SafeString.new(%(\n<span class="for-screen-reader">Show auto-login QR code</span>\n#{ChatLayout.icon("qr-code.svg", 20, "colorize--black")}\n))
      }.raw + "\n" +
      button_to_copy_to_clipboard(url) {
        ERB::SafeString.new(%(\n<span class="for-screen-reader">Copy auto-login link</span>\n#{ChatLayout.icon("copy-paste.svg", 20, "flex-item-no-shrink colorize--black")}\n))
      }.raw + "\n" +
      web_share_session_button(url, "Your sign-in link",
        "This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out.") {
        ERB::SafeString.new(%(\n<span class="for-screen-reader">Share auto-login link</span>\n#{ChatLayout.icon("share.svg", 20, "flex-item-no-shrink colorize--black")}\n))
      }.raw +
      %(\n</div>\n</div>\n</fieldset>))
  end
end
