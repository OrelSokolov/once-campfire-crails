# Зеркалит once-campfire/config/routes.rb. Матчер линейный: литеральные
# сегменты до динамических; отличия от Rails помечены комментариями.
CRails.application.routes.draw do
  root "welcome#show"

  resource :first_run, only: [:show, :create]

  get "/up", to: "up#show"

  resource :session, only: [:new, :create, :destroy]

  # Rails: resources :transfers c update; порт создаёт перенос на put/patch.
  scope path: "session" do
    get   "/transfers/:id", to: "sessions/transfers#show"
    put   "/transfers/:id", to: "sessions/transfers#create"
    patch "/transfers/:id", to: "sessions/transfers#create"
  end

  resource :account, only: [:edit, :update] do
    scope module: "accounts" do
      resources :bots, except: [:show]
      # controller: имя уже во множественном (pluralize дал бы "custom_styless")
      resource :custom_styles, only: [:edit, :update], controller: "custom_styles"
    end
  end
  # resource :key, only: :update внутри resources :bots — PUT/PATCH
  put   "/account/bots/:bot_id/key", to: "accounts/bots/keys#update"
  patch "/account/bots/:bot_id/key", to: "accounts/bots/keys#update"
  get "/account", to: "accounts#edit"
  get "/account/custom_styles", to: "accounts/custom_styles#edit"
  get "/account/logo", to: "accounts/logos#show", as: "account_logo"
  delete "/account/logo", to: "accounts/logos#destroy"
  patch "/account/users/:user_id", to: "accounts/users#update", as: "account_user"
  delete "/account/users/:user_id", to: "accounts/users#destroy", as: "account_user"
  post "/account/join_code", to: "accounts/join_codes#create"

  direct :fresh_account_logo do |options|
    route_for :account_logo, v: Current.account.try(&.updated_at).try(&.to_fs(:number)), size: options["size"]?
  end

  get "/join/:code", to: "joins#show", as: "join"
  post "/join/:code", to: "joins#create"
  get "/qr_code/:id", to: "qr_code#show"
  get "/webmanifest", to: "pwa#manifest"
  get "/webmanifest.json", to: "pwa#manifest"
  get "/service-worker", to: "pwa#service_worker"

  # Литеральные /users/me/* до resources :users; аватар — по :token.
  get "/users/me/sidebar", to: "users/sidebars#show", as: "user_sidebar"
  get "/users/me/profile", to: "users/profiles#show", as: "user_profile"
  patch "/users/me/profile", to: "users/profiles#update", as: "user_profile"
  # scope defaults: { user_id: "me" }: Web Push подписки текущего юзера.
  get    "/users/me/push_subscriptions", to: "users/push_subscriptions#index",
    as: "user_push_subscriptions"
  post   "/users/me/push_subscriptions", to: "users/push_subscriptions#create"
  delete "/users/me/push_subscriptions/:id", to: "users/push_subscriptions#destroy"
  post   "/users/me/push_subscriptions/:push_subscription_id/test_notifications",
    to: "users/push_subscriptions/test_notifications#create"
  get "/users/:token/avatar", to: "users/avatars#show", as: "user_avatar"
  resources :users, only: [:show]
  # resource :ban внутри resources :users: бан/разбан из users/show.
  post   "/users/:user_id/ban", to: "users/bans#create"
  delete "/users/:user_id/ban", to: "users/bans#destroy"

  get "/autocompletable/users", to: "autocompletable/users#index", as: "autocompletable_users"

  direct :fresh_user_avatar, User do |user, options|
    route_for :user_avatar, user.avatar_token, v: user.updated_at!.to_fs(:number)
  end

  # namespace :rooms как в Rails; :room_id вместо :id — на URL не влияет.
  namespace :rooms do
    resources :opens, only: [:new, :create, :edit, :update], param: :room_id
    resources :closeds, only: [:new, :create, :edit, :update], param: :room_id
    resources :directs, only: [:new, :create]
    # Настройки direct-комнаты — rooms/directs#edit.
    get "/directs/:room_id/edit", to: "directs#edit"
  end

  resources :rooms, only: [:show, :destroy] do
    resources :messages, except: [:new], param: :message_id
    # scope module: "rooms": resource :refresh/:involvement как в Rails.
    scope module: "rooms" do
      resource :refresh, only: [:show]
      resource :involvement, only: [:show, :update]
    end
    # /rooms/:id/settings — алиас GET involvements#show (routes.js:597).
    get "settings", to: "rooms/involvements#show"
    get "@:message_id", to: "rooms#show", as: :at_message

    # Bot-API: scope path ":bot_key" с controller: "messages/by_bots".
    scope path: ":bot_key", as: :bot do
      post   "messages", to: "messages/by_bots#create"
      get    "messages", to: "messages/by_bots#index"
      get    "messages/:message_id", to: "messages/by_bots#show"
      patch  "messages/:message_id", to: "messages/by_bots#update"
      put    "messages/:message_id", to: "messages/by_bots#update"
      delete "messages/:message_id", to: "messages/by_bots#destroy"
      post   "messages/:message_id/boosts", to: "messages/boosts/by_bots#create"
      delete "messages/:message_id/boosts/:boost_id", to: "messages/boosts/by_bots#destroy"
    end
  end

  resources :messages, only: [] of String, param: :message_id do
    # Boosts: scope module: "messages" внутри resources :messages.
    scope module: "messages" do
      resources :boosts, only: [:new, :index, :create, :destroy]
    end
  end

  get "/rails/active_storage/blobs/redirect/:token/:filename", to: "active_storage#blob"
  get "/rails/active_storage/representations/redirect/:token/:variation/:filename", to: "active_storage#representation"

  # unfurl_link: только create — og-метаданные ссылки (POST {url}).
  resource :unfurl_link, only: [:create]

  # searches: index/create + collection clear (routes.rb:94-96).
  resources :searches, only: [:index, :create] do
    delete :clear, on: :collection
  end
end
