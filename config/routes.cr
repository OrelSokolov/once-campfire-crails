# Зеркалит once-campfire/config/routes.rb. Матчер линейный (первое
# совпадение выигрывает), поэтому литеральные сегменты рисуем до
# динамических: `/users/me/...` до `resources :users`, видовые роуты
# комнат (`/rooms/opens/...`) до `resources :rooms`.
#
# Отличия от Rails-файла помечены комментариями: порт держит один
# RoomsController на все виды комнат (в Rails — Rooms::Opens и др.),
# а часть действий названа иначе (searches#show вместо index,
# sessions/transfers#create на put/patch вместо update).
CRails.application.routes.draw do
  root "welcome#show"

  resource :first_run, only: [:show, :create]

  get "/up", to: "up#show"

  resource :session, only: [:new, :create, :destroy]

  # В Rails это nested resources :transfers c update; у порта put/patch
  # создают перенос (sessions/transfers#create) — поэтому явные роуты.
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
  get "/account/logo", to: "accounts/logos#show"
  delete "/account/logo", to: "accounts/logos#destroy"
  patch "/account/users/:user_id", to: "accounts/users#update"
  delete "/account/users/:user_id", to: "accounts/users#destroy"
  post "/account/join_code", to: "accounts/join_codes#create"

  get "/join/:code", to: "joins#show"
  post "/join/:code", to: "joins#create"
  get "/qr_code/:id", to: "qr_code#show"
  get "/webmanifest", to: "pwa#manifest"
  get "/webmanifest.json", to: "pwa#manifest"
  get "/service-worker", to: "pwa#service_worker"

  # Литеральные /users/me/* — до resources :users (см. шапку). Аватар
  # ищется по :token, а не :user_id, как в Rails-неймспейсе users.
  get "/users/me/sidebar", to: "users/sidebars#show"
  get "/users/me/profile", to: "users/profiles#show", as: "user_profile"
  patch "/users/me/profile", to: "users/profiles#update"
  # scope defaults: { user_id: "me" } внутри resources :users: подписки
  # текущего пользователя на Web Push (JS-колокол _bell.html.erb).
  get    "/users/me/push_subscriptions", to: "users/push_subscriptions#index",
    as: "user_push_subscriptions"
  post   "/users/me/push_subscriptions", to: "users/push_subscriptions#create"
  delete "/users/me/push_subscriptions/:id", to: "users/push_subscriptions#destroy"
  post   "/users/me/push_subscriptions/:push_subscription_id/test_notifications",
    to: "users/push_subscriptions/test_notifications#create"
  get "/users/:token/avatar", to: "users/avatars#show"
  resources :users, only: [:show]
  # resource :ban внутри resources :users (scope module: "users"):
  # бан/разбан пользователя — кнопки в users/show.html.erb.
  post   "/users/:user_id/ban", to: "users/bans#create"
  delete "/users/:user_id/ban", to: "users/bans#destroy"

  get "/autocompletable/users", to: "autocompletable/users#show"

  # Виды комнат — как в Rails (`namespace :rooms`): контроллеры
  # Rooms::Opens/Closeds/Directs; :room_id — имя параметра, которое
  # читают контроллеры (в Rails для opens/closeds — :id, здесь оставлено
  # :room_id из порта; URL от этого не зависит).
  namespace :rooms do
    resources :opens, only: [:new, :create, :edit, :update], param: :room_id
    resources :closeds, only: [:new, :create, :edit, :update], param: :room_id
    resources :directs, only: [:new, :create]
    # Настройки direct-комнаты (rooms/directs/edit.html.erb) рендерит
    # rooms/directs#edit.
    get "/directs/:room_id/edit", to: "directs#edit"
  end

  resources :rooms, only: [:show, :destroy] do
    resources :messages, except: [:new], param: :message_id
    # scope module: "rooms" как в Rails: Rooms::RefreshesController и
    # Rooms::InvolvementsController (resource :refresh/:involvement).
    scope module: "rooms" do
      resource :refresh, only: [:show]
      resource :involvement, only: [:show, :update]
    end
    # resource :settings, only: :show — в express общий handler для
    # /rooms/:id/settings и /rooms/:id/involvement (routes.js:597):
    # алиас GET-ветки involvements#show.
    get "settings", to: "rooms/involvements#show"
    get "@:message_id", to: "rooms#show", as: :at_message

    # Bot-API: /rooms/:id/:bot_key/messages (в Rails — scope path:
    # ":bot_key" внутри nested с controller: "messages/by_bots").
    scope path: ":bot_key", as: :bot do
      post   "messages", to: "messages/by_bots#bot_create"
      get    "messages", to: "messages/by_bots#bot_index"
      get    "messages/:message_id", to: "messages/by_bots#bot_show"
      patch  "messages/:message_id", to: "messages/by_bots#bot_update"
      put    "messages/:message_id", to: "messages/by_bots#bot_update"
      delete "messages/:message_id", to: "messages/by_bots#bot_destroy"
      post   "messages/:message_id/boosts", to: "messages/boosts/by_bots#bot_create"
      delete "messages/:message_id/boosts/:boost_id", to: "messages/boosts/by_bots#bot_destroy"
    end
  end

  resources :messages, only: [] of String, param: :message_id do
    # Boosts — Messages::BoostsController (в Rails — scope module:
    # "messages" внутри resources :messages).
    scope module: "messages" do
      resources :boosts, only: [:new, :index, :create, :destroy]
    end
  end

  get "/rails/active_storage/blobs/redirect/:token/:filename", to: "active_storage#blob"
  get "/rails/active_storage/representations/redirect/:token/:variation/:filename", to: "active_storage#representation"

  # unfurl_link: ресурс только create — og-метаданные вставленной
  # ссылки (unfurl_controller.js шлёт POST {url}).
  resource :unfurl_link, only: [:create]

  # GET /searches у порта — searches#show (в Rails resources даёт index).
  get "/searches", to: "searches#show", as: "searches"
  post "/searches", to: "searches#create"
  delete "/searches/clear", to: "searches#clear"
  post "/searches/clear", to: "searches#clear"
end
