# CustomStylesHelpers — ERB-хелперы app/views/custom_styles/edit.html.erb:
# head + body + nav (только «назад» на /account/edit) + main.
# Включается в CustomStylesController; общий icon/page_close — ViewHelpers.
module CustomStylesHelpers
  def page_open(user : User) : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("custom-styles", "Custom CSS", user,
      nav_html: ChatLayout.nav_back("/account/edit")))
  end
end
