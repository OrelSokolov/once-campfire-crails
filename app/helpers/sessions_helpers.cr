# SessionsHelpers: ERB helpers for app/views/sessions/new.html.erb.
module SessionsHelpers
  include ActionController::Helper

  # Oracle: `"shake" if flash[:alert]` — the alert lands via prepare_login.
  def panel_modifier : String
    login_alert ? " shake" : " "
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end

  def version : String
    ENV["APP_VERSION"]? || "parity"
  end
end
