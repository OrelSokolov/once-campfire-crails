# SessionTransfersHelpers: ERB helpers for app/views/sessions/transfers/show.html.erb.
module SessionTransfersHelpers
  def page_open : ERB::SafeString
    ERB::SafeString.new(ChatLayout.page_open("transfer", "Campfire"))
  end
end
