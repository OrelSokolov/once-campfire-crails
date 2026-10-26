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
- **`form_with url: "/account.#{id}"` вместо `form_with model:`** — ЗАКРЫТО
  2026-10-26 (инкремент «2.4-формы», см. ниже): все формы на `model:`,
  `/account.<id>` генерируется polymorphic-резолвером.
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
  2026-10-25: `User` — `ar_enum :role, [:member, :administrator, :bot]`
  (предикаты `administrator?`/`bot?` вместо `role == 1/2`); Symbol/String
  в `Model.new(enum_col:)` — active_record.cr v0.1.17. `Push::Subscription` —
  `validates :endpoint, presence: true` + `validate :validate_endpoint_url`
  с `errors.add` (вместо ручного `valid_subscription?`).

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

## STYLE_1to1 — инкремент 2026-10-25 (фаза 2, хвост)

Закрытые пункты плана (все — патчи шардов по регламенту: lib → проверка →
myshards → bump → push → пин в shard.yml → shards update → сборка):

- **`SecureRandom.alphanumeric`** — active_support.cr **0.1.11**
  (`src/secure_random.cr`); joinable: `SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")`
  1:1 с оракулом.
- **`CRails.application.configure do |config| ... end`** — railties.cr
  **0.1.16**; config/environments/{development,production}.cr переведены
  на блок (блок принимает `config` явно — instance_eval в Crystal нет).
- **`allow_unauthenticated_access(**options)` / `allow_bot_access`** —
  DSL-макросы в concerns/authentication.cr 1:1 с class_methods оракула;
  ~10 контроллеров переведены с `skip_before_action :require_authentication`;
  добавлен `before_action :deny_bots` (+`deny_bots` через `bot_request?` —
  в порте нет authenticated_by-трекинга, см. ниже). by_bots-контроллеры
  сохраняют порт-специфичный `skip_before_action :require_authentication`
  (бот-аутентификация через `require_bot`, не через require_authentication,
  как в оракуле).
  Грабли макросов: проброс `**options` из макроса в макрос через сырой
  `**options` кладёт неразрешённый Splat-узел в позиционный splat адресата
  (в-filter `__skip_` с пустым именем); правильный паттерн —
  `{% if options.empty? %} ... {% else %} ..., {{ options.double_splat }}{% end %}`.
- **`belongs_to ... default: -> { Current.user }`** — active_record.cr
  **0.1.18** (after_initialize: FK nil + new_record? → присваивание
  ассоциации из proc); применено в message/room/boost (creator/booster).
- **`broadcast_to` kwargs-форма** — action_cable.cr **0.1.5**:
  `broadcast_to room, action: :start, user: current_user.slice(:id, :name)`;
  явный per-type JSON-эмиттер (PG::Numeric не имеет to_json(builder), а
  union-диспетчеризация Object#to_json(io) уходит в builder). Каналы:
  `current_user` в ApplicationCable::Channel (по current_user_id),
  typing_notifications 1:1 с оракулом.
- **`Base#slice(*attrs)`** — active_record.cr 0.1.18 (ActiveSupport
  Object#slice для записей).
- **jbuilder** — jbuilder.cr **0.1.1**: объектная форма `json.cache! user do`
  (ключ из `cache_key` записи); партиалы users/_user, messages/_message,
  messages/boosts/_boost переведены на `json.cache!` + `json.extract!`
  + `room_message_url(...)` вместо `jb_origin + "/rooms/..."`.
  Компромиссы: `json.extract! obj, ...` вместо синтаксически невозможного
  `json.(obj, ...)`; `as_local:` вместо `as:` (ключевое слово Crystal);
  `fresh_user_avatar_url` остаётся `jb_origin + ChatLayout.fresh_user_avatar_path`
  (нужен `direct`-роутинг — см. 2.7). Url-хелперы в партиалах — через
  делегат `JbuilderTemplate::UrlContext` (включать UrlHelpers в сам
  JbuilderTemplate нельзя: его method_missing-макрос затирает DSL Jbuilder);
  для этого `__crails_url_helper` стал публичным — action_pack.cr **0.2.15**.

Отложено (переносится в фазу 3 / отдельные инкременты):

- **2.4 collection-рендер/dom_id** — сайдбар/профили собираются
  compile-time через ChatERB/ChatLayout (SidebarDirect-снапшоты); перевод
  на `render partial: collection:` = разбор мега-хелперов (фаза 3,
  инкременты уже идут). `dom_id(record, prefix)` в шарде есть, но STI-записи
  порта — класс Room с type-колонкой, class.name даёт "room", так что
  остаются порт-хелперы Room#dom_id / ChatERB#dom_id / route_key.
- **2.1 adoption `.or/.pluck/.merge/find_each`** — все сайты оракула
  (bannable, room#destroy_later, broadcasts, message_pusher) в порте
  живут внутри WriteQueue-транзакций на сыром SQL; конверсия = фаза 3
  «WriteQueue → AR-методы», отдельно не делается.
- **Фаза 3** (ResponseCache around_action, WriteQueue → AR) — не начата
  в этом инкременте.

## STYLE_1to1 — фаза 3: WriteQueue → AR + ResponseCache observer, 2026-10-25

**ResponseCache**: ручные `Campfire::ResponseCache.invalidate!` (32 вызова в
контроллерах/моделях/джобах/каналах) удалены. Инвалидация теперь автоматическая,
как в oracle response_cache.rb: epoch (`PRAGMA data_version`) читается с
выделенного read-only observer-коннекта (`DB::Database#checkout` навсегда +
fiber-семафор `Channel(Bool)` поверх — leased-коннект не файбер-безопасен).
Observer никогда не пишет, поэтому data_version двигается на КАЖДЫЙ коммит
приложения, включая writer-fiber этого же процесса (пул видел только чужие).
Все три кэша (Response/Identity/Fragment) остались epoch-keyed — ничего
больше не нужно. Метод `invalidate!` оставлен как ручной таран.

**WriteQueue → AR** (структура WriteQueue сохранена — это сериализация
writer-fiber'а, а не SQL; AR-вызовы внутри транзакций идут через пиннед
`Base.__session`):

- **bannable** 1:1 с оракулом: `sessions.pluck(:ip_address).compact_blank.uniq`
  → `bans.create!`, `sessions.delete_all`, `banned!`/`active!` (enum-банги),
  `bans.delete_all`; у User появился `has_many :bans`. Порт-отклонение:
  close_remote_connections/RemoveBannedContentJob — после коммита (оракул
  в транзакции, но у него job-enqueue сам after-commit).
- **room#destroy_later**: `becomes(Rooms::Closed).save!` (switch класса ДО
  save — иначе after_save_commit Rooms::Open наградит всех активных юзеров
  мембершипами на пути к удалению), `memberships.pluck(:user_id)` →
  `delete_all`. STI-тип пишется коротким спеллингом ('Closed') как раньше.
- **room#unread_memberships**: `memberships.visible.disconnected.
  where.not(user_id:).update_all(...)` + `unless direct? → where(unread_at:
  nil)` — семантика оракула (уже-unread не переписываются), прежний
  полный-rewrite убран.
- **Room#reset_remote_connections_of / destroy_one_message_at_a_time**
  (oracle API): `User.where(id:).find_each(&.reset_remote_connections)`,
  `messages.find_each(&.destroy)` + `destroy`; Room::DestroyJob — тело
  оракула (raw teardown удалён, broadcast per-message удалён — стримы
  участников уже закрыты reset'ом).
- **Message**: `has_many :boosts, dependent: :destroy`; `after_destroy_commit
  :remove_from_index` (include Message::Searchable, instance-метод);
  rich_text-строка умирает с записью — **active_record_cr v0.1.19** добавил
  `has_rich_text` after_destroy cleanup + CollectionProxy#pluck cast.
  messages/by_bots destroy — чистый `message.destroy`.
- **message_creator**: rich_text INSERT → `record.body=` (upsert через
  after_save has_rich_text, через __session в транзакции). Осталось сырым:
  `Message::Attachment.store` (ActiveStorage-внутренности) и FTS-инсерт
  (plain text вычисляется из запроса — оракул делает это в record_creation,
  у порта сознательно в MessageCreator, см. выше по notes).
- **messages/by_bots update**: `body=` + `save` (bump updated_at) вместо
  raw UPDATE rich_text + touch; FTS update_in_index остался.
- **RemoveBannedContentJob**: `user.messages.order("id").each { destroy +
  broadcast_remove }` (оракул: message.destroy + message.broadcast_remove).
- **Ban.banned?**: `where(...).exists?` вместо raw query_one.

`.or`/`.merge` не применены: сайты оракула (broadcasts/message_pusher) в порту
идут другими путями (unread — update_all, push — PushMessageJob), конверсии
требуют реструктуризации, отложено.

## STYLE_1to1 — 2.6 turbo_stream + 2.4 button_to, 2026-10-25

**turbo_stream-вьюхи на TagBuilder** (2.6 закрыт): create/destroy/
refreshes/show .turbo_stream.erb рендерят через `turbo_stream.append/
remove/replace` из turbo_cr (StreamsHelper включён в ApplicationController —
оракул-механика turbo-rails: хелпер доступен всем вью). Ответы сверены
байт-в-байт с предыдущей ручной сборкой (smoke tmp/ts-smoke: различия только
id/таймстампы сообщений и порт в origin-URL). Особенности:

- `dom_id(room, :messages)` — ApplicationHelper-оверлоад `dom_id(Room,
  prefix)` → Room#dom_id (STI-тип): записи порта — класс Room, шардовый
  RecordIdentifier дал бы `messages_room_5` вместо `messages_rooms_open_5`.
  Не-STI записи (Message) идут через шардовый RecordIdentifier как в оракуле.
- refresh-вьюха: `(turbo_stream.append ... if @new_messages.any?)` в скобках
  (модификатор-if — выражение только в скобках, Crystal) + контент-форма
  вместо блока с partial-collection (мега-хелперы — фаза 3); одинокий "\n"
  при пустых new сохранён (erubi-семантика переноса после emit-тега).
- messages/by_bots#create — тот же TagBuilder inline (порт-специфичный
  turbo-stream ответ сохранён; оракул отдаёт head :created).

**button_to — важное уточнение про артефакты** (исправлено в action_view_cr
v0.1.19): паритетный харнесс **сортирует атрибуты тегов** при сохранении
артефактов (capybara-tests/harness/normalize.rb: attrs.sort) — «алфавитный»
порядок форм/кнопок в артефактах это нормализация сравнения, а не байты
оракула. Сырой гем (8.1.4 и 8.2.0.alpha git-реф приложения — код в этой
области идентичен, проверено запуском ruby из рефа) даёт insertion-порядок:
`<form class method action>`, `__av_method_field` (autocomplete гейтится
remove_hidden_field_autocomplete, load_defaults 8.2 → off), атрибуты кнопки
без сортировки + `type="submit"` в конце, `hidden="hidden"`. Промежуточные
v0.1.17–0.1.18 (gate button_to_edge_82) шли по нормализованным артефактам и
откачены; спек button_to_spec.cr шарда фиксирует сырые байты гема.

Конвертация ручных форм на `button_to` (2.4 закрыт, кроме ChatLayout):
users/show (×4 + helper button_to_direct_room_with), push_subscriptions (×2),
searches/_recent_searches, users/sidebars placeholders, rooms/directs/edit,
rooms/involvements/_show, profiles_helper#involvement_chip,
rooms_helper#button_to_delete_room. Попутно исправлены латентные байтовые
баги порядка атрибутов (push-формы, involvement-форма _show, boost-форма).
Остались ручными (ChatLayout — статический билдер без вью-контекста,
переносятся вместе с разбором мега-хелперов в фазе 3): join_code-форма
(порядок уже 8.2-корректный) и boost_dom-форма (порядок исправлен на
action-class-method).

## STYLE_1to1 — 2.7 direct-роутинг + expires_in + фикс jbuilder, 2026-10-26

**`direct`/`route_for`** (2.7 закрыт, action_pack.cr **0.2.16**): Drawer#direct —
макрос (`direct :helper do |options|` / `direct :helper, User do |user, options|`,
тип позиционного аргумента передаётся явно — типизировать параметры блоков в
Crystal нельзя; захваченный блок не наследует `with drawer yield`-ресивер, поэтому
блоки зовут top-level `route_for`). Диспетчеризация — в `__crails_url_helper`:
`fresh_account_logo_path`/`_url` генерируются method_missing'ом как обычные
именованные хелперы и работают во всех контекстах (контроллеры, ERB-вью,
jbuilder через делегаты `JbuilderTemplate#fresh_*`). Аргумент travels в
generic-`DirectArgBox` (Reference в юнионах Crystal объявить нельзя). Query-nil
значения теперь пропускаются (паритет Rails url_for). Adopted в app: routes.cr —
два direct-блока 1:1 + `as: "account_logo"`/`as: "user_avatar"` + блочная форма
`resources :searches do delete :clear, on: :collection end` (verb-макросы
принимают Symbol; лишний POST /searches/clear удалён); удалены обёртки
ChatLayout-путей (accounts_helper/sessions_helpers fresh_account_logo_path,
profiles_helper fresh_avatar_path) — вью зовут сгенерированные хелперы;
`User#avatar_token` уже был 1:1; снапшотный hot-path (бусты/сайдбар) остаётся на
`ChatLayout.fresh_user_avatar_path(uid, updated_at)` — внутри тот же route_for.

**`expires_in`** (2.3 хвост) — action_pack.cr **0.2.17**: ConditionalGet#
expires_in (Cache-Control Rails-порядок public/private → max-age →
must-revalidate; `private:` через **opts — ключевое слово). Adopted:
qr_code#show → `expires_in 1.year, public: true` (байты
`Cache-Control: public, max-age=31536000`); logos/cached_responses остаются на
ручной механике (byte-parity ETag/Cache-Control уже выверен).

**jbuilder.cr 0.1.2 — фикс stack overflow** (латентный, воспроизводился на
/webmanifest.json со времён 0.1.1): вызов `_ks(<Node-union>)` уходил в
method_missing → `set!("_ks", node)` → set! → `_ks(...)` → бесконечная рантайм-
рекурсия. Фикс: catch-all `_ks`-оверлоад (raise) + guard в method_missing —
подчёркнутые методы дают compile error вместо молчаливой рекурсии.

Компромиссы direct: один позиционный аргумент на хелпер (фиксированная арность
захваченных блоков); тип аргумента явный (`direct :fresh_user_avatar, User`).

## STYLE_1to1 — фаза 3, инкремент 2: accounts/_invite партиал, 2026-10-26

Секция invite системного приветствия (join-link поле, QR/copy/share,
регенерация join-code) вынесена из ChatLayout.system_welcome в ERB-партиал
app/views/accounts/_invite.html.erb (оракул-структура, плоская конвенция
порта): render(partial:) из RoomsHelper#invitation_html, регистрация в
RoomsController.compile_partials (compile_partials подкласса затеняет
диспетчер ApplicationController — общие партиалы регистрируются в рендерящем
контроллере). ChatLayout.system_welcome(origin, invite_html) остался
статической обёрткой (логотип/перевод/текст) — вне горячего пути.

web_share_session_button переехал из Users::ProfilesHelper в ClipboardHelper
(глобально wired; в оракуле он в ProfilesHelper, но Rails даёт все хелперы
всем вью — порт-эквивалент: общий модуль). Байты welcome-блока сверены
«до/после»: 4 дельты, все к реальному оракулу — href последним в QR-ссылке
(link_to гема), hidden="hidden" (tag.button гема), form class→method→action
(button_to гема), перевод строки после </form> (erubi-семантика); остальное
байт-в-байт. Последняя ручная форма ChatLayout — boost_dom (горячий путь
fragment-кэша сообщений, конверсия = разбор messages_html на коллекционный
рендер, отдельный инкремент фазы 3).

## STYLE_1to1 — 2.5 GlobalID: GlobalID.create, единое GlobalID.app, 2026-10-26

active_record_cr **v0.1.21** + turbo_cr **v0.1.7** + action_cable_cr **v0.1.6**:

- **`GlobalID.create(record)`** (active_record_cr v0.1.21) возвращает
  `GlobalID::Reference` (в геме — инстанс GlobalID; имя занято модулем) с
  `to_s`/`to_param`; распарсенный Reference хранит app-сегмент URI, `to_s`
  round-trip'ит. Identification-поверхность на AR::Base: `to_gid` /
  `to_gid_param` (переехали из turbo_cr — как в globalid-railtie).
- **`gid_model_name`-шов**: гем строит gid из `model.class.name`; у порта
  STI-строки таблицы комнат материализуются базовым классом Room, поэтому
  `Base#gid_model_name` (дефолт `class.name`) переопределяется в Room —
  ручной `Room#to_gid_param` удалён, байты gid не изменились (смоук:
  b64("gid://campfire/Rooms::Open/<id>") в обе стороны, round-trip через
  Locator, обе орфографии STI).
- **Единое имя приложения**: `Turbo.app` (default "crails") и
  `ActionCable.gid_app` (ENV) убраны — `GlobalID.app` settable-property
  (default ENV CRAILS_APP_NAME, устанавливается в config/cable.cr
  `GlobalID.app = "campfire"`), как единственный GlobalID.app рантайма
  оракула. turbo-спек ставит `GlobalID.app = "oracle"` (было Turbo.app).
- **`serialize_broadcasting` → `to_gid_param` записи** (action_cable_cr
  v0.1.6): имена стримов `stream_for`/`broadcast_to` для записей теперь
  byte-for-byte совпадают с turbo_stream_from (раньше — b64 из
  `gid_app`/`class.name`: "gid://app/Room/N"); RoomChannel/
  TypingNotificationsChannel имена стримов теперь как у оракула.
  Осталось: cookie-фикстура stream_for_spec дрейфует против типизации
  action_pack_cr CookieOptions (pre-existing, connection-секция; gid-часть
  проверена byte-точным мини-спеком sf_gid_param).
- **Неопубликованные lib-патчи 2.1-хвоста**: инкремент про
  STI-нормализацию/or/merge/insert_all/excluding/signed_id описывает
  изменения, которых ещё нет в опубликованном active_record.cr — v0.1.20
  занят GlobalID-коммитом; их публикация должна выйти v0.1.21+.

## STYLE_1to1 — 2.4 form_with model:, 2026-10-26 (инкремент «2.4-формы»)

Все формы, где оракул пишет `form_with model:`, переведены с `url:`+`scope:`
на модель (accounts/edit ×4, bots new/edit, accounts/users/_user,
custom_styles/edit, first_runs, joins, messages/edit обе, messages/boosts/new,
rooms/_form, rooms/directs/new, profile_form_with).

- **Формы байт-паритетны**: `action="/account.<id>"` даёт polymorphic-резолвер
  (path_for для REST-маршрутов аппендит остаточный позиционный аргумент через
  «.» — Journey-семантика `(.:format)`), сконы полей — `form_scope` модели
  (Room — STI-нормализованный `rooms_open`, см. Room#form_scope; остальные —
  underscored class name). Явные `value:` убраны: значения из модели, nil →
  атрибут опускается (Rails TextField).
- **Латентный баг закрыт**: PATCH/PUT `/account.<id>` раньше не матчился
  вовсе (форма аккаунта 404ила на сабмите); опциональный `(.:format)`-сегмент
  (флаг на REST-маршрутах) матчит обе формы, суффикс → params["format"].
- **Нейминг REST-маршрутов как в Rails**: create зовёт collection-имя,
  update/destroy — member-имя (раньше оставались безымянными; polymorphic
  `model:` и `_path`-хелперы теперь резолвятся: account, account_bot,
  room_message, message_boosts…). Роуты порта: добавлены имена `join`,
  `user_profile` (patch), `account_user` (patch/destroy) — зеркалит
  `as:`-имена routes.rb оракула.
- **Поддержка шардов**: `FormModel` на `ActiveRecord::Base` (form_scope/
  form_model_name — ActiveModel::Naming; form_attributes — через
  virtual-dispatch стаб `attributes` на Base); action_view_cr `form_models`
  структурно по `Array` — литерал `[message, Boost.new]` типизируется
  `Array(Message | Boost)` и из-за инвариантности дженериков не попадает в
  `when Array(FormModel)` (без фикса boosts-форма теряла и URL, и сконы).
- **Экранирование data-action в ERB**: в Hash-опциях пишется голый `->`
  (`data: {action: "x->c#m"}`), tag_options сам экранирует в `-&gt;`;
  `-&gt;` в исходнике даёт двойное экранирование.
- **Не переведено**: composer_form_tag (FormBuilder#rich_text_area + блочный
  lexxy-виджет — нужен в шарде; вместе с content_for :footer), 2 ручные
  формы ChatLayout (фаза 3).
- **Параллельная сессия**: работа велась одновременно с GlobalID-инкрементом
  (2.5) в том же worktree — lib/* дважды перезаписывались shards install,
  часть app-правок путешествовала через stash. Форм-патчи шардов живут в
  lib/ (бэкап action_pack routes: tmp/routes_patched_backup.cr); публикация
  active_record 0.1.22 (FormModel) подхвачена параллельным WIP в
  ~/myshards/active_record.cr; action_view (form_models/Array) и action_pack
  (нейминг + .:format) — не опубликованы, версии 0.1.20/0.2.19 свободны.

## STYLE_1to1 — 2.3 cookies: hash-форма + Symbol-ключи, 2026-10-26

- **`cookies.signed.permanent[name] = { value:, httponly:, same_site: }`** —
  action_pack_cr v0.2.18: hash-форма `jar[name] = { value:, ... }` (Rails
  CookieJar#[]= c хешем опций) и Symbol-ключи имён во всех джарбах.
  Подпись/шифрование перенесены из `set` в commit-фазу цепочки (child →
  parent): цепочка `cookies.signed.permanent[...]` подписывает значение,
  которое parent-permanent уже успел снабдить expires = 20 лет, — конверт
  несёт message-level `exp` (как в геме, oracle
  ck_signed_permanent_hash*); обратный порядок `.permanent.signed[...]`
  коммитит подпись раньше — exp конверта остаётся nil (существующее
  поведение, ck_permanent_signed). Оба порядка byte-verified против
  actionpack 8.1.4 (оракул + реверс verify_cookies.rb).
- **Plain/permanent jar со скаляром** — `cookies.permanent[:last_room] =
  room.id` пишет wire `"42"` (gem-конвертация to_s, oracle ck_permanent_int);
  порту больше не нужен `.not_nil!.to_s` (остался `not_nil!` — id nilable).
- Adopted в app: authentication/joins/transfers —
  `cookies.signed.permanent[:session_token] = { value:, httponly: true,
  same_site: :lax }` 1:1 с authentication.rb:94 (раньше —
  `cookies.signed.set(..., expires: Time.utc + 20.years, ...)` с ручным
  20-летним expires); tracked_room_visit/rooms_controller —
  `cookies.permanent[:last_room] = room.id.not_nil!`;
  session_lookup/sessions/welcome/accounts_helper/push_subscriptions —
  Symbol-ключи чтения (`cookies.signed[:session_token]?`,
  `cookies[:last_room]?`) и удаления (`cookies.delete(:session_token)`).
- Осталось осознанным: page-cache вручную (cached_responses) вместо
  around_action — ETag/Cache-Control byte-parity (см. инкремент
  2.7/expires_in выше).

## STYLE_1to1 — 2.4 lexxy-формы + фаза 3 бусты, 2026-10-26

- **`FormBuilder#rich_text_area`/`rich_textarea_tag`** — action_view.cr
  **v0.1.21**: `<lexxy-editor>` (Rails 8.2 ActionText lexxy-editor),
  class-дефолт `lexxy-content`, name/id из скоупа (id только при
  form_with_generates_ids, явный `id:` бьёт), явный `value:` бьёт атрибут
  модели, data-direct-upload-url/blob-url-template — из
  переопределяемых `rich_text_direct_upload_url`/
  `rich_text_blob_url_template` хост-контекста (Rails: main_app
  .rails_direct_uploads_url/rails_service_blob_url), блок (mention
  prompts) не экранируется. Спек: spec/rich_text_area_spec.cr (3
  кейса), весь suite 255/255.
- **composer_form_tag/content_for :footer** — rooms/show/_composer
  .html.erb вербатим с оракулом: ChatERB включает umbrella
  `ActionView::Helpers` (FormBuilder.@view типизирован модулем —
  отдельных инклудов недостаточно) + composer_form_tag 1:1 (RoomsHelper
  оракула; data-options/data-actions приватными методами), footer
  читается через `content_for(:footer)` в RoomsHelper#room_page.
  messages/edit: form.rich_text_area с `value: body.to_s` —
  editable_body-трансформация аттачментов (Trix-era embeds/mentions
  rebuild) не портирована (notes/known-gaps.md).
- **Новые хелперы/роуты**: app/helpers/rich_text_helper.cr (1:1),
  drop_target_helper.cr (1:1), RichTextHelper wired глобально
  (`helper :rich_text`), роут `as: "autocompletable_users"` (Rails
  auto-name). tag.lexxy_prompt с дефисными kwargs невозможен (TagBuilder
  macro re-emission) — content_tag("lexxy-prompt", ...) в
  mention_prompt_tag.
- **Латентный баг HEAD вскрыт пересборкой**: `current_user!` в
  authentication.cr и ApplicationCable::Channel вызывал сам себя
  (миграция bang-методов) — стек-оверфлоу на любом запросе;
  исправлен на `current_user.not_nil!`.
- **Фаза 3, бусты**: messages/boosts/_boosts + _boost — ERB-партиалы
  (вербатим-структура оракула, с отступами и голым `->` в литеральных
  атрибутах), рендер через BoostsERB (по образцу ChatERB) и
  `render partial: "messages/boosts/boost", collection:`
  (erb_cr collection-рендер, счётчик игнорируется диспетчером
  локалей). ChatLayout.boosts_dom/boost_dom — делегаты (boost_dom
  остаётся входной точкой бусткастов в boosts/by_bots контроллерах);
  BoostEntry получил message_id; FragmentCache::RENDER_VERSION s1→s2.
  Верификация: DOM-эквивалент рендера до/после (html.parser,
  токены+отсортированные атрибуты); байты теперь совпадают с СЫРЫМ
  оракулом (rails_oracle_boosts_full.html), а не только с
  нормализованными артефактами: button_to form class→method→action,
  _method-инпут type→name→value + ` />`, `<img ... />` у аватаров.
  Нормализация харнесса раньше маскировала оба отклонения.
- **Erubi-семантика пробелов**: erubi (trim) стирает whitespace-хвост
  перед code-тегом `<% %>` и newline после него; port template_processor
  стирает только newline после — блоки приносят хвостовые отступы в
  `<%= helper do %>`-захват (`</button>` с отступом). Нормализуется
  харнессом; при желании 1:1 — отдельный патч erb_cr.

## STYLE_1to1 — вскрытые регрессии HEAD (stale bin/app маскировал), 2026-10-26

Пересборка bin/app (прошлая сборка — 23 окт, до коммитов bang-методов и
2.4-форм) вскрыла три регрессии, невидимые для twinshot на старом
бинарнике:

- **`current_user!` саморекурсия** (authentication.cr,
  ApplicationCable::Channel) — миграция bang-методов оставила
  `def current_user!; current_user!; end`; стек-оверфлоу на любом
  запросе. Фикс: `current_user.not_nil!`.
- **FormBuilder затирал явный `name:`** — action_view.cr **v0.1.22**:
  `__ff_input`/`hidden_field`/`text_area`/`check_box`/`radio_button`
  ставят скоуп-имя только при отсутствии явного name: (Rails
  add_default_name_and_id). Инкремент 2.4-форм перевёл rooms/_form на
  `model: room` (скоуп rooms_open), а шаблонная явная `name: "room[name]"`
  молча затиралась → params.require(:room) пустой, сабмиты комнат/ботов
  падали.
- **bots#create двойная вставка membership** — after_create_commit
  :grant_membership_to_open_rooms (миграция колбэков) уже даёт новому
  юзеру membership во все open-комнаты («on conflict do nothing»), а
  контроллер повторял цикл Room.opens вручную → UNIQUE constraint
  (memberships.room_id, user_id) → 500 на создании бота. Ручной цикл
  удалён (оракул: User.create_bot! без ручных membership).

Урок: после инкрементов, меняющих bin/-бинарник, пересобирать bin/app ДО
twinshot review — харнесс грузит bin/app (harness/boot.rb:168), не
рабочее дерево.

## STYLE_1to1 — финал review default: последние два диф-паттерна, 2026-10-26

Прогон final3 (35 фейлов «2 structural lines») разложился ровно на два
паттерна; оба закрыты, review default — 129/129 (структура), png-фейлы 0:

- **`hidden_field` с nil-атрибутом писал `value=""`** — Rails читает
  value_before_type_cast и опускает атрибут при nil (пустая строка
  по-прежнему даёт `value=""`). action_view.cr **v0.1.23**
  (`raw_value(attr).nil?`-гейт в `hidden_field`); билдер композера
  `message[client_message_id]` на каждой room-странице — именно этот
  паттерн дал большинство фейлов.
- **Хвост `accounts/_invite`**: оракул после erubi-trim оставляет
  текстовый узел `  ` (два пробела) между `</form>` и `</div>`:
  `<% end %><% end %>  </div>` одной строкой (порт-процессор дропает
  один перенос после кодового тега, чисто пробельный текст эмиссирует
  как есть).

Механика артефактов (важно для будущих дифов): HTML-артефакты идут через
браузер (page.html/outerHTML), пайплайн стирает whitespace-узлы,
содержащие `\n`, но сохраняет чисто пробельные (без переноса) —
идентификатор `\n    ` в артефакте невидим, `  ` — видим и структурно
значим.

Оставшиеся png-варнинги (soft_check в twinshot.yml: quick-boost.png,
watercooler-paged.png, ранее custom-boost.png): аватарные webp-варианты
`resize_to_limit [512,512] + webp` — Rails кодирует libvips/libwebp,
порт — image_processing_cr; байтовый парити энкодеров недостижим,
пиксельный шум 0.2–0.35% сидит ровно в круглых зонах аватаров
(подтверждено кластеризацией диф-пикселей: три 32px круга аватаров
сообщений + 45px аватар хедера в watercooler). HTML этих же тестов
байт-в-байт идентичен.
