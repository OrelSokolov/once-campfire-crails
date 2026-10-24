# Отклонения от Rails-стиля, не реализуемые (или отложенные) на Crystal

Фиксация по требованию AGENTS.md: «если что-то не получается реализовать —
добавляй в записки». Базлайн — `twinshot review code`.

## Синтаксис Crystal (не воспроизводится в принципе)

- **`private`-секция с отступом** (`private` + indented `def`) — Crystal
  допускает только `private def foo` в одну строку.
- **`include A, B, C` одной строкой** — Crystal требует отдельный `include`
  на каждый модуль.
- **`%i[ show destroy ]`-литералы** — только `[:show, :destroy]`.
- **`class << self` / `extend ActiveSupport::Concern`** — модули Crystal
  подключаются напрямую, concern-механика не нужна.
- **`class X < ActiveRecord::Migration[7.2]`** — парсер Crystal не
  допускает `[` в позиции superclass (только generic-скобки `Bar(T)`);
  `Migration.[](version)` в шарде работает как выражение (0.1.15), но
  форма наследования непереносима — миграции остаются `< ActiveRecord::Migration`.

## Требуют патчей шардов (план, Фаза 7)

- **`ActiveRecord::Migration[8.1]`** — нужен class-method `self.[]`
  в `active_record_cr` (миграции после этого 1:1 с оракулом).
- **`render layout: "rooms/layouts/new" do ... end`** в шаблонах —
  layout-партиал с блоком; сейчас вьюхи инлайнят
  `render partial: ..., locals: {...}` (compile_partials).
- **`has_many ... do ... end` (extension-блоки ассоциаций)** —
  `Room#memberships.grant_to/revoke_from/revise`; компромисс:
  class-методы `Membership`.

## Осознанные отклонения (behavior/инфраструктура)

- **`icon()` вместо `image_tag "x.svg"`** — пребилд-манифест даёт
  `/assets/<fingerprinted>` src; `image_tag` с голым именем выдал бы
  `/images/x.svg` и сломал бы byte-parity HTML.
- **`form_with url: "/account.#{id}"` вместо `form_with model:`** — механика
  есть (railties_cr подключает `FormHelper.polymorphic_path`), но замена
  отложена: URL и сконы форм должны совпасть до байта.
- **`boosts_dom` вместо `render "messages/boosts/boosts"`** — HTML
  сообщения/бустов собирает ChatLayout (compile-time), view-уровневого
  `render`-партиала в порте нет.
- **Комментарии-шапки на русском** — в оракуле их нет; контрактные
  пояснения (PageCache/IdentityCache, byte-parity ловушки) оставлены —
  их удаление без переноса куда-либо потеряло бы контекст порта.
- **`_show.html.erb` вместо `show.html.erb`** (`rooms/involvements`,
  ранее `users/sidebars`) — implicit-scan `action_pack_cr` компилирует
  `app/views/<dir>/<action>.html.erb` в контексте контроллера, где локалов
  ChatERB нет; префикс-подчёркивание выводит файл из скана (шаблон живёт
  только в ChatERB#compile_template).
- **`redirect_to root_url` вместо `post_authenticating_url`**
  (sessions, sessions/transfers) — stored-location механика аутентификации
  Rails не портирована; редирект всегда на корень.
- **`Users::AvatarsController#destroy` отсутствует** — оракул после
  удаления аватара делает `redirect_to user_profile_url`; у порта нет
  DELETE-роута аватара (смена аватара — через profiles#update).
- **users#new/create живут в `JoinsController`** (`/join/:code`) —
  оракул держит их в `UsersController`; структура порта отражает express-
  референс. `redirect_to new_session_url(email_address:)` из rescue-ветки
  оракула не портирован (join при дубле email — 422).
- **`rooms/settings` — алиас `rooms/involvements#show`** — в express
  (routes.js:597) общий handler; оракул рисует отдельный
  `resource :settings` без контроллера в дереве.

## Выравнивания поведения (сделано, отличалось от оракула)

- `RoomsController#set_room`: раньше 404 "Room not found" на чужую/несущ.
  комнату → теперь membership-scope + `redirect_to root_path, alert:`
  как в оракуле.
- `MessagesController` edit/update/destroy: раньше «только автор» с телом
  403 "Cannot edit/delete this message" → теперь `ensure_can_administer`
  (автор или админ, пустой 403) как в оракуле.
- `by_bots` update/destroy: аналогично — `ensure_can_administer` вместо
  проверки только создателя.
- `Rooms::Opens/Closeds#edit/update` на несуществующую комнату: раньше
  head 404 → теперь redirect через set_room (как в оракуле).
- **Callbacks/enum-миграция моделей (2026-10-24)**: `User` — `ar_enum :status`
  (+ default :active) и `after_create_commit :grant_membership_to_open_rooms`
  (SQL insert-select `on conflict do nothing`); `Membership` — enum `prefix:
  :involved_in` + `after_destroy_commit { user.reset_remote_connections }`;
  `Rooms::Open` — `after_save_commit :grant_access_to_all_users` (guard
  `type_previously_changed?(to: "Open")` — порт пишет короткий STI-тип);
  `Session` — `has_secure_token` + `before_create` last_active_at; `Search` —
  `after_create :trim_recent_searches`; `Account::Joinable` — before_create
  join_code + `reset_join_code`. Гранты в rooms/joins/first_run переехали
  из контроллеров в модели; involvement грантов выровнен с оракулом
  ('mentions', было 'everything'); revoke в update_room теперь `destroy`
  (срабатывает after_destroy_commit), insert-гранты — `on conflict do nothing`.

## Коллбэки, не перенесённые в модели (2026-10-24)

- **`Message#after_save :record_creation, if: :previously_new_record?` и
  `after_create_commit -> { room.push_later(self) }`** — остаются в
  `MessageCreator`: FTS5-индексу нужен предвычисленный plain text из
  `body_html` запроса (из модели недоступен), а enqueue задач обязан
  происходить строго ПОСЛЕ коммита production-транзакции (отдельная queue
  БД; дедлок на conc=16 — см. message_creator.cr). В модели оставлен
  только `before_create -> { client_message_id ||= UUID.random.to_s }`.
- **`Opengraph::Metadata` `before_validation :sanitize_fields`** — модель
  не ActiveRecord (ActiveModel-объект с property), макросы коллбэков
  живут в AR::Base; санитизация остаётся class-методом `Metadata.sanitize`.
- **`has_many :reachable_messages, through: :rooms, source: :messages`**
  (chained through: `rooms` сам through `memberships`) — шардовый through
  композируется только над прямым has_many; скоуп написан вручную
  (`User#reachable_messages`, тот же subquery-паттерн, что `Room.visible`).
- **find-bang в контроллерах (2026-10-24)** — сконвертированы чистые сайты
  (`UsersController#show`, `Users::Bans`, `Accounts::Users`,
  `Accounts::Bots` edit/update/destroy, `Accounts::Bots::Keys`):
  `find?` + ручной 404 → `Relation#find` (RecordNotFound → 404-страница
  middleware, как rescue-ladder Rails). НЕ конвертированы: `set_room` /
  `set_message` / `set_boost` (messages, boosts, by_bots) и autocompletable —
  их лукапы membership-скоупы с выверенными телами ответов, прямого
  аналога `Current.user.reachable_messages.find` в шарде нет (через
  has_many :through с source у Relation нет). Класс-уровень `Model.find(String)`
  появился в шарде (base.cr `find(id : Int64 | Int32 | String)`) —
  паттерны `.all.find(str)` конвертированы (2026-10-24).


## Структурный паритет (missing-файлы), 2026-10-23 — plans/structure-parity.md

Фазы A–F выполнены: helpers переименованы под оракул (accounts_helper,
application_helper, users/{avatars,profiles,sidebar}_helper …), модели
разобраны из misc.cr/opengraph.cr по файлам оракула + concerns
(user/*, message/*, room/message_pusher, membership/connectable,
account/joinable, push/*), каналы room/read_rooms/typing_notifications +
RoomStreamsAreAuthorized (reopen: нет `prepend`), джобы
(ApplicationJob-база + Bot::WebhookJob, Room::{Destroy,PushMessage}Job,
Message::BroadcastUnreadRoomJob, RemoveBannedContentJob), concerns
контроллеров (raw_request_body, version_headers, room_scoped,
authentication/session_lookup, active_storage_authentication,
allow_browser). Механика concerns: include в конце concern-файла через
reopen (glob сортирует `user.cr` раньше `user/avatar.cr`; include в
корневом файле невозможен — модуль ещё не загружен); class-методы —
через `ActiveSupport::Concern` + `class_methods do … end` +
`macro included; extend_class_methods!; end`.

Оставшиеся отклонения (не воспроизводится / отложено):

- **`ApplicationJob`** — ActiveJob нет; база задаёт только сигнатуру
  `self.perform(data)`, диспетчер — `Campfire::JobQueue` (kind-строки).
- **`RoomStreamsAreAuthorized`** — вместо `prepend` reopened-класс
  `Turbo::StreamsChannel#subscribed` (app/channels/concerns/).
- **`Message::Pagination::Page < Array`** — дженерики Crystal не
  наследуются; методы возвращают `Array(Message)`.
- **`Push::Subscription`** — `set_table_name "push_subscriptions"`
  (codegen вывел бы `push/subscriptions`; table_name_prefix нет).
- **`RecordCache`, `Purchaser`, `Room::MessagesCount`** (колонки/триггеры
  schemes нет) — потребителей в порте нет, файлы не созданы.
- **View-слой**: значительная часть HTML оракула собирается
  compile-time в ChatLayout/ChatERB, а не ERB-файлами: сообщения
  (`_message/_presentation/_actions/_template/_unrenderable`,
  `boosts/_boost(s)`, `users/_mention`, `action_text/*`,
  `active_storage/blobs/_blob`, `layouts/application`, `_lightbox`,
  `accounts/_invite`, `rooms/show*`, `rooms/layouts/*`) — маппинг
  «oracle-путь → генератор» в комментариях chat_layout.cr
  (grep по имени файла). Файлы с ChatERB-локалами остаются с
  `_`-префиксом (`users/sidebars/_show`, `rooms/involvements/_show`) —
  implicit-scan action_pack_cr скомпилировал бы их в контексте
  контроллера без локалов; исключение из скана — только патчем шарда.
- **Мейлер** (`layouts/mailer.{html,text}`) — почты в порте нет.
- **Пагинация accounts/users** (`_next_page_container`,
  `index.turbo_stream`) — список рендерится целиком.
- **`messages#room_not_found`** — порт отдаёт `render plain: "Room
  not found"` (404), оракул — turbo-frame «This room was deleted.».
- **`users#new`** живёт в `JoinsController#show` — см. выше (express).
- **`set_platform` / `inline_script_hashes` / CSP** — платформа покрыта
  `ApplicationPlatform`-хелперами; CSP-заголовок не формируется вовсе
  (нужен отдельный план: initializer + middleware).
- **`webhook deliver`** (`Webhook#deliver`) живёт в `Bot::WebhookJob`
  (доставка + реплай), не в модели.
- **Rails-инфра** (bin/*, puma/resque/brakeman/bundler-audit,
  config/environments, config/initializers, hooks/, lib/rails_ext,
  lib/web_push (→ app/jobs/web_push.cr), lib/restricted_http (→
  Opengraph DNS-pinning), script/admin, script/dev, bench/*) —
  soft_check в twinshot.yml; эквиваленты: config/application.cr,
  src/app.cr, tasks/*.rake, bench-workspace/.
