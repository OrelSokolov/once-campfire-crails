account = @account

json.name account.try(&.name).to_s.presence || "Campfire"
json.icons [
  {src: fresh_account_logo_path(size: "small"), sizes: "192x192", purpose: nil},
  {src: fresh_account_logo_path, sizes: "512x512", purpose: nil},
  {src: fresh_account_logo_path, sizes: "512x512", purpose: "maskable"},
] do |icon|
  json.src icon[:src]
  json.type "image/png"
  json.sizes icon[:sizes]
  json.purpose icon[:purpose] if icon[:purpose]
end
json.start_url "/"
json.display "standalone"
json.scope "/"
json.description "A chat app from the makers of Basecamp and HEY."
json.categories ["social", "business", "productivity"]
json.theme_color "#ffffff"
json.background_color "#ffffff"
json.shortcuts [
  {name: "New chat room", description: "Open Campfire and start a new chat room",
   url: "rooms/opens/new", icon: "add.svg"},
  {name: "My profile", description: "Open Campfire and view your profile",
   url: "/users/me/profile", icon: "person.svg"},
] do |shortcut|
  json.name shortcut[:name]
  json.description shortcut[:description]
  json.url shortcut[:url]
  json.icons [{src: ChatLayout.asset(shortcut[:icon]), sizes: "any"}] do |icon|
    json.src icon[:src]
    json.sizes icon[:sizes]
  end
end
json.screenshots [
  {"screenshots/android-chat.png",
   "Campfire is an installable, self-hosted group chat system."},
  {"screenshots/android-sidebar.png",
   "Easily invite people. Make rooms. @mentions, DMs, and mobile support."},
  {"screenshots/android-dark-mode.png",
   "Full support for dark mode, customizable to your brand."},
] do |screenshot|
  json.src ChatLayout.asset(screenshot[0])
  json.sizes "1080x2400"
  json.form_factor "narrow"
  json.label screenshot[1]
end
