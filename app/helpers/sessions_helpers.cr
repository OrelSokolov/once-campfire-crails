# SessionsHelpers — ERB-хелперы app/views/sessions/new.html.erb:
# head логина без chat-обвязки, flash/alert, value-атрибут email-инпута,
# логотип аккаунта, лайтбокс. Включается в SessionsController; общий
# icon/campfire_icon_src — ViewHelpers.
module SessionsHelpers
  # head без chat-обвязки + turbo-visit-control reload
  # (layouts/application.html.erb логина).
  def login_head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("Sign in", nil, nil, chat: false,
      head_extra: %(<meta name="turbo-visit-control" content="reload">\n)))
  end

  # flash.now[:alert] (application.html.erb:38-48) — после </nav>.
  def flash_html : ERB::SafeString
    return ERB::SafeString.new("") unless login_alert
    ERB::SafeString.new(%(<div class="flash" data-controller="element-removal" data-action="animationend-&gt;element-removal#remove">\n) \
                        %(<div class="flash__inner shadow" style="--flash-background: var(--color-negative)">\n) \
                        %(<img src="#{ChatLayout.asset("alert.svg")}" aria-hidden="true" width="24" height="24" class="colorize--white">\n) \
                        %(</div>\n<span class="for-screen-reader" role="alert" aria-atomic="true">Too many requests or unauthorized.</span>\n</div>\n))
  end

  # panel shake при неудачном входе (class="panel<%= panel_modifier %>").
  def panel_modifier : String
    login_alert ? " shake" : " "
  end

  # Логотип аккаунта (logos/app-icon.png, fingerprinted asset).
  def logo_src : String
    ChatLayout.fresh_account_logo_path(Account.take)
  end

  # value-атрибут email-инпута (пустой, когда параметра нет).
  def email_value : ERB::SafeString
    return ERB::SafeString.new("") if email.empty?
    ERB::SafeString.new(%( value="#{HTML.escape(email)}"))
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end

  def lightbox_dialog : ERB::SafeString
    ERB::SafeString.new(ChatLayout.lightbox_dialog)
  end

  # Бейдж версии (экранируется в <%= %>).
  def version : String
    ENV["APP_VERSION"]? || "parity"
  end
end
