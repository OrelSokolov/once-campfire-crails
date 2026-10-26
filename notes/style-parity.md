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
