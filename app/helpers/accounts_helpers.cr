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
    ERB::SafeString.new(ChatLayout.copy_button(url, "Copy join link"))
  end

  # account_nav.eta: назад + ссылки на ботов/кастомные стили (админ).
  def account_nav(user : User) : String
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
end
