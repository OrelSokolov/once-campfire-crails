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
  get "/account", to: "accounts#edit"
  get "/account/custom_styles", to: "accounts/custom_styles#edit"
  get "/account/logo", to: "accounts/logos#show"
  delete "/account/logo", to: "accounts/logos#destroy"
  patch "/account/users/:user_id", to: "accounts/users#update"
  delete "/account/users/:user_id", to: "accounts/users#destroy"
  post "/account/join_code", to: "accounts/join_codes#create"

  get "/join/:code", to: "joins#show"
  post "/join/:code", to: "joins#create"
  get "/qr_code/:id", to: "qr_codes#show"
  get "/webmanifest", to: "pwa#manifest"
  get "/webmanifest.json", to: "pwa#manifest"

  # Литеральные /users/me/* — до resources :users (см. шапку). Аватар
  # ищется по :token, а не :user_id, как в Rails-неймспейсе users.
  get "/users/me/sidebar", to: "users/sidebars#show"
  get "/users/me/profile", to: "users/profiles#show"
  patch "/users/me/profile", to: "users/profiles#update"
  get "/users/:token/avatar", to: "users/avatars#show"
  resources :users, only: [:show]

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
    get "refresh", to: "rooms#refresh"
    get "involvement", to: "rooms#involvement"
    put "involvement", to: "rooms#update_involvement"
    get "@:message_id", to: "rooms#show", as: :at_message

    # Bot-API: /rooms/:id/:bot_key/messages (в Rails — scope path:
    # ":bot_key" внутри nested с controller: "messages/by_bots").
    scope path: ":bot_key", as: :bot do
      post "messages", to: "messages/by_bots#bot_create"
      get  "messages", to: "messages/by_bots#bot_index"
      get  "messages/:message_id", to: "messages/by_bots#bot_show"
      post "messages/:message_id/boosts", to: "messages/boosts/by_bots#bot_create"
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

  # GET /searches у порта — searches#show (в Rails resources даёт index).
  get "/searches", to: "searches#show"
  post "/searches", to: "searches#create"
  delete "/searches/clear", to: "searches#clear"
  post "/searches/clear", to: "searches#clear"
end
