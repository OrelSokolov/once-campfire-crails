# SessionTransfersHelpers — ERB-хелперы app/views/session_transfers/
# show.html.erb: head формы авто-логина. Включается в
# SessionTransfersController; общий icon/page_close — ViewHelpers.
module SessionTransfersHelpers
  def head : ERB::SafeString
    ERB::SafeString.new(ChatLayout.head("Session transfer", nil, nil, chat: false))
  end
end
