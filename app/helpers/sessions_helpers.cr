# SessionsHelpers: ERB helpers for app/views/sessions/new.html.erb.
module SessionsHelpers
  def login_head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("Sign in", nil, chat: false,
      head_extra: %(<meta name="turbo-visit-control" content="reload">\n)))
  end

  def flash_html : ERB::SafeString
    return ERB::SafeString.new("") unless login_alert
    ERB::SafeString.new(%(<div class="flash" data-controller="element-removal" data-action="animationend-&gt;element-removal#remove">\n) \
                        %(<div class="flash__inner shadow" style="--flash-background: var(--color-negative)">\n) \
                        %(<img src="#{ChatLayout.asset("alert.svg")}" aria-hidden="true" width="24" height="24" class="colorize--white">\n) \
                        %(</div>\n<span class="for-screen-reader" role="alert" aria-atomic="true">Too many requests or unauthorized.</span>\n</div>\n))
  end

  def panel_modifier : String
    login_alert ? " shake" : " "
  end

  # Oracle url-helper name (fresh_account_logo_path): serves the stock icon
  # or the logo variant, cache-busted by the attachment timestamp.
  def fresh_account_logo_path : String
    ChatLayout.fresh_account_logo_path(Account.take)
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def lightbox_dialog : ERB::SafeString
    ERB::SafeString.new(ChatLayout.lightbox_dialog)
  end

  def version : String
    ENV["APP_VERSION"]? || "parity"
  end
end
