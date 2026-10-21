# SessionTransfersHelpers — ERB-хелперы app/views/sessions/transfers/
# show.html.erb: полный layout-каркас формы авто-логина (Rails: layout
# c title «Campfire», неавторизованный viewer). Включается в
# Sessions::TransfersController; page_close — ViewHelpers.
module SessionTransfersHelpers
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("transfer", "Campfire"))
  end
end
