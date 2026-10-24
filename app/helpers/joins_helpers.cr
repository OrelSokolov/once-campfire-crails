# ERB helpers for app/views/joins/show.html.erb, included in JoinsController.
module JoinsHelpers
  def page_open : ERB::SafeString
    account = self.account.not_nil!
    nav = %(<div class="flex-item-justify-end"><a href="#{new_session_path}" class="btn flex-item-justify-end">) +
      ChatLayout.icon("login-keys.svg") +
      %(<span class="for-screen-reader">Sign in</span></a></div>)
    ERB::SafeString.new(ChatLayout.page_open("join", "Join #{account.name}",
      body_class: "signup", nav_html: nav))
  end
end
