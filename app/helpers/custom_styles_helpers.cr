# CustomStylesHelpers: ERB helpers for app/views/custom_styles/edit.html.erb.
module CustomStylesHelpers
  include ActionController::Helper
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("custom-styles", "Custom CSS",
      nav_html: nav_back_to(edit_account_path).raw))
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end
end
