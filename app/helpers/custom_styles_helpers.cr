# CustomStylesHelpers: ERB helpers for app/views/custom_styles/edit.html.erb.
module CustomStylesHelpers
  include ActionController::Helper
  def translation_button(key : String) : ERB::SafeString
    ERB::SafeString.new(TranslationsHelper.translation_button(key))
  end
end
