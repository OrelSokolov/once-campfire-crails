# Зеркалит once-campfire/config/routes.rb. Матчер линейный (первое
# совпадение выигрывает), поэтому литеральные сегменты рисуем до
# динамических: `/users/me/...` до `resources :users`, видовые роуты
# комнат (`/rooms/opens/...`) до `resources :rooms`.
#
# Отличия от Rails-файла помечены комментариями: порт держит один
# RoomsController на все виды комнат (в Rails — Rooms::Opens и др.),
# а часть действий названа иначе (searches#show вместо index,
# session_transfers#create на put/patch вместо update).
CRails.application.routes.draw do
  root "welcome#show"

  resource :first_run, only: [:show, :create]

  get "/up", to: "up#show"

  resource :session, only: [:new, :create, :destroy]

  # В Rails это nested resources :transfers c update; у порта put/patch
  # создают перенос (session_transfers#create) — поэтому явные роуты.
  scope path: "session" do
    get   "/transfers/:id", to: "session_transfers#show"
    put   "/transfers/:id", to: "session_transfers#create"
    patch "/transfers/:id", to: "session_transfers#create"
  end

  resource :account, only: [:edit, :update] do
    resources :bots, except: [:show]
    # controller: имя уже во множественном (pluralize дал бы "custom_styless")
    resource :custom_styles, only: [:edit, :update], controller: "custom_styles"
  end
  get "/account", to: "accounts#edit"
  get "/account/custom_styles", to: "custom_styles#edit"
  get "/account/logo", to: "logos#show"
  delete "/account/logo", to: "logos#destroy"

  get "/join/:code", to: "joins#show"
  post "/join/:code", to: "joins#create"
  get "/qr_code/:id", to: "qr_codes#show"
  get "/webmanifest", to: "pwa#manifest"
  get "/webmanifest.json", to: "pwa#manifest"

  # Литеральные /users/me/* — до resources :users (см. шапку). Аватар
  # ищется по :token, а не :user_id, как в Rails-неймспейсе users.
  get "/users/me/sidebar", to: "sidebars#show"
  get "/users/me/profile", to: "profiles#show"
  patch "/users/me/profile", to: "profiles#update"
  get "/users/:token/avatar", to: "avatars#show"
  resources :users, only: [:show]

  get "/autocompletable/users", to: "autocompletable_users#show"

  # Виды комнат. В Rails это `namespace :rooms` с ресурсами opens/
  # closeds/directs и контроллерами Rooms::Opens и др.; порт держит
  # один RoomsController — controller: "rooms", kind приходит из
  # defaults, :room_id — имя параметра, которое читает контроллер.
  scope path: "rooms", as: "rooms" do
    resources :opens, only: [:new, :create, :edit, :update],
      controller: "rooms", param: :room_id, defaults: {kind: "opens"}
    resources :closeds, only: [:new, :create, :edit, :update],
      controller: "rooms", param: :room_id, defaults: {kind: "closeds"}
    resources :directs, only: [:new, :create]
    # Настройки direct-комнаты (directs/edit.html.erb) рендерит rooms#edit.
    get "/directs/:room_id/edit", to: "rooms#edit"
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
      post "messages", to: "messages#bot_create"
      get  "messages", to: "messages#bot_index"
      get  "messages/:message_id", to: "messages#bot_show"
      post "messages/:message_id/boosts", to: "boosts#bot_create"
    end
  end

  resources :messages, only: [] of String, param: :message_id do
    resources :boosts, only: [:new, :index, :create, :destroy]
  end

  get "/rails/active_storage/blobs/redirect/:token/:filename", to: "active_storage#blob"
  get "/rails/active_storage/representations/redirect/:token/:variation/:filename", to: "active_storage#representation"

  # GET /searches у порта — searches#show (в Rails resources даёт index).
  get "/searches", to: "searches#show"
  post "/searches", to: "searches#create"
  delete "/searches/clear", to: "searches#clear"
  post "/searches/clear", to: "searches#clear"
end
