# CustomStylesHelpers — ERB-хелперы app/views/custom_styles/edit.html.erb:
# head + body + nav (только «назад» на /account/edit) + main.
# Включается в CustomStylesController; общий icon/page_close — ViewHelpers.
module CustomStylesHelpers
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("custom-styles", "Custom CSS",
      nav_html: ChatLayout.nav_back(edit_account_path)))
  end

  # translation_button (translations_helper): details/popup меню переводов.
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.translation_button(key))
  end
end
