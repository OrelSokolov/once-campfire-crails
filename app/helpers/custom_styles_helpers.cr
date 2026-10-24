# CustomStylesHelpers: ERB helpers for app/views/custom_styles/edit.html.erb.
module CustomStylesHelpers
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("custom-styles", "Custom CSS",
      nav_html: ChatLayout.nav_back(edit_account_path)))
  end

  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end
end
