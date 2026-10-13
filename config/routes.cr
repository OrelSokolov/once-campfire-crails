CRails.application.routes.draw do
  get "/up", to: "up#show"
  get "/session/new", to: "sessions#new"
  post "/session", to: "sessions#create"
  get "/rooms/:id", to: "rooms#show"
  get "/rooms/:id/messages", to: "messages#index"
  post "/rooms/:id/messages", to: "messages#create"
  get "/users/me/sidebar", to: "sidebars#show"
  get "/searches", to: "searches#show"
  get "/users/:token/avatar", to: "avatars#show"
end
