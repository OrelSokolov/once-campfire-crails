# План: стиль 1:1 с Rails-оракулом (STYLE_1to1)

База: отчёт `twinshot-report/code/report_for_agent.md` — 283 фейла из 834.
Классификация отличий: (a) недостающая фича шарда Crails, (b) неизбежный синтаксис
Crystal, (c) стилистическая проблема порта. План покрывает (a) и (c); (b) не трогаем.

Регламент правки шардов (AGENTS.md): патч в локальный шард → проверка → патч в
`~/myshards/` → публикация с bump `vX.Y.Z` → bump версии в проекте → повторный тест →
`rake build:crails` → коммит.

---

## Фаза 1. Стилистические чистки порта (без фреймворка)

### 1.1. Русские комментарии-шапки (~40 файлов)
- В каждом `app/**/*.cr` убрать блоки вида `# Порт ... референса ...`,
  `# ... (x.rb оракула): ...` из шапки файла.
- Смысловые объяснения отклонений перенести в `notes/style-parity.md` или
  `notes/known-gaps.md`; в коде оставить краткие английские комментарии как в оракуле.
- Затронуто: почти все channels, controllers, models, helpers, views.

### 1.2. `require_admin` → `ensure_can_administer` (~8 файлов)
- Переименовать, рендер заменить на `head :forbidden` (после реализации `head`
  в фазе 2.3; иначе — временный эквивалент с тем же именем и телом оракула).

### 1.3. Дубли хелперов
- `selected_user_ids` — один общий private-хелпер (сейчас 2 копии:
  rooms_controller, directs_controller).
- Cookie-декод `when String ... when JSON::Any` — вынести в один хелпер (3 копии).

### 1.4. Мусор в репо
- Убрать дубли vendor JS (`actioncable` + `action_cable` + `actioncable.esm`,
  `lexxy` ×3, `stimulus` ×3).
- Smoke/debug-скрипты (`script/*_smoke*`, `script/*_debug*`), bench-инфраструктуру —
  за пределы parity-дерева (structure-parity).

### 1.5. Форматирование под rubocop-стиль оракула
- `[ "blob_id" ]` вместо `["blob_id"]` в миграциях и app/ (пробел внутри скобок
  массива), где так пишет оракул.

Приоритет 1.1 → 1.2 → 1.3 → 1.5 → 1.4.

---

## Фаза 2. Фичи шардов (по убыванию эффекта)

### 2.1. active_record_cr — ассоциации и find (~25 файлов)
- [x] `has_many through:` с belongs_to-источником (FK на средней таблице) +
  скоупы на `Relation(T)` (чейнинг `user.rooms.without_directs`) +
  `method_missing`-делегирование на `CollectionProxy` — опубликовано
  **active_record_cr v0.1.12**; применено: `user.rooms` в модели,
  `room_scope` 1:1 в rooms/opens/closeds/directs, lookup в messages/refreshes.
- [x] `find`/`find?`/`find_by`/`find_by!` на `Relation` и `CollectionProxy`;
  404 по `RecordNotFound` уже есть в railties_cr middleware (rescue-лестница).
  Заменить ручные nil-проверки на `find` в ~10 контроллерах — хвост закрыт
  через `reachable_messages`-скоуп (см. notes/style-parity.md, 2026-10-24).
- [x] Callbacks DSL: `before_create`, `after_save, if:`, `after_create_commit`,
  `after_destroy_commit`, `after_save_commit ... if type_previously_changed?(to:)`
  + dirty-API (`*_previously_changed?`) — миграция моделей 2026-10-24
  (notes/style-parity.md). Исключения (осознанные): Message#record_creation/
  push_later остаются в MessageCreator (FTS5 + enqueue после коммита),
  Opengraph::Metadata — не-AR модель — см. notes.
- [x] `enum` c `prefix:`, `default:` и предикатами: `administrator?`, `banned?`,
  `active?` — status/involvement (2026-10-24) + role (2026-10-25,
  active_record.cr v0.1.17 — Symbol/String в `new`); `banned!`/`active!`
  в Bannable остаются сырым SQL (WriteQueue-транзакция, notes).
- [x] `belongs_to ... default: -> { Current.user }` (message, boost, room) —
  active_record_cr v0.1.18 (after_initialize: FK nil + new_record?);
  применено в message/room/boost (2026-10-25).
- [x] `has_many ... dependent: :delete_all/:destroy` — шард поддерживает,
  применено точечно (room.messages); extension-блоки (`has_many do`) —
  компромисс Membership.grant_to (notes/style-parity.md).
- [~] Query API: `where.not`/`update_all` — есть и применяются; `.merge`, `.or`,
  `pluck`, `find_each` — есть в шарде и применены (2026-10-25: pluck —
  bannable/room#destroy_later, find_each — Room#reset_remote_connections_of/
  destroy_one_message_at_a_time, where.not/update_all — unread_memberships);
  `.or`/`.merge` остаются неприменёнными (сайты оракула — broadcasts/
  message_pusher на иных путях порта); `joins(:assoc)` —
  только has_many-конвенция (membership-скоупы на сырых JOIN);
  `insert_all`/`excluding` — не применены.
- [~] `signed_id(purpose:)` / `find_signed!` — вручную через MessageVerifier
  (sha256 + sha1 fallback для legacy express-токенов) в avatar/transferable/
  authentication; шардовой реализации нет.
- [x] `has_secure_token` (Session); `has_secure_password`/`authenticate_by` —
  компромисс: ручной `User.authenticate` с DUMMY_BCRYPT (timing-защита 1:1).
- [x] `validates presence:` + `validate` + `errors.add` — Push::Subscription
  (2026-10-25), контроллер на `valid?`/`save`.
- [ ] STI-нормализация type: `WHERE type IN ('Open', 'Rooms::Open')` —
  осознанный компромисс (notes/known-gaps.md).
- [~] `ActiveRecord::Migration[7.2]`-версии — форма наследования непереносима
  (парсер Crystal); `Migration.[]`-заглушка в шарде есть (0.1.15).

### 2.2. active_support_cr — мелкие методы (~10 файлов)
- [x] `presence`, `blank?`, `present?` для `String?` — в шарде; для
  `Parameters` — не сделано.
- [~] `Time.current` — в шарде; `to_fs(:number)` — есть, `:epoch` и `to_f` —
  нет; в app не используются.
- [x] `in?`, `many?`, `to_sentence`, `compact_blank` — в шарде (в app
  применяется точечно); `.inquiry` — нет.
- [x] `SecureRandom.alphanumeric` — active_support_cr v0.1.11
  (2026-10-25); joinable 1:1 с оракулом.

### 2.3. action_pack_cr — контроллерный DSL
- [x] `head :no_content` / `head :forbidden` — стабилен, применён
  (`ensure_can_administer` 1:1); хвост `render(plain: "", status:)` в
  unfurl/by_bots/boosts/logos — осознанный (тела ответов).
- [x] `respond_to do |format|` — есть в шарде; в app не используется
  (update/autocompletable вручную разбирают Accept).
- [~] `stale?(etag:)`/`fresh_when` — есть в шарде; `expires_in` —
  action_pack_cr v0.2.17 (2026-10-26), adopted в qr_code#show
  (`expires_in 1.year, public: true`); logos/cached_responses — ручная
  механика (ETag/Cache-Control byte-parity). Попутно: jbuilder_cr v0.1.2
  — фикс stack overflow на webmanifest (рекурсия _ks → method_missing).
- [x] `params.require(:x).permit(...)` — символная форма во всех контроллерах.
- [x] DSL `allow_unauthenticated_access(**options)` / `allow_bot_access` —
  макросы в concerns/authentication.cr 1:1 с class_methods оракула
  (2026-10-25), ~10 контроллеров переведены; добавлен `before_action
  :deny_bots` (порт-эквивалент через bot_request? — authenticated_by-трекинга
  нет); by_bots сохраняет порт-специфичный skip require_authentication
  (require_bot). Макро-грабли `**options`-проброса — notes/style-parity.md.
- [x] `around_action` + `before_action, if:/unless:` — есть в шарде;
  page-cache в app вручную (cached_responses) — осознанный компромисс
  (ETag/Cache-Control byte-parity, notes/style-parity.md).
- [x] `cookies.signed.permanent[...] = { value:, httponly:, same_site: }` —
  hash-форма `[]=` + Symbol-ключи имён — action_pack_cr v0.2.18 (2026-10-26);
  подпись/шифрование перенесены в commit-фазу цепочки джарбов, поэтому
  `cookies.signed.permanent[...]` несёт message-level exp = 20 лет, а
  `.permanent.signed[...]` — exp nil (обе цепочки byte-verified против
  actionpack 8.1.4, oracle/cookies_expected.yml). Adopted: authentication/
  joins/transfers (`signed.permanent[:session_token] = { value:, httponly:,
  same_site: :lax }` 1:1 с authentication.rb:94), tracked_room_visit/
  rooms (`cookies.permanent[:last_room] = room.id`), session_lookup/
  sessions/welcome/хелперы — Symbol-ключи чтения/удаления.

### 2.4. action_view_cr — вьюхи (~20 файлов)
- [x] `image_tag` — механика есть (пребилд-манифест), `icon()` остаётся
  для byte-parity (notes/style-parity.md).
- [x] `form_with model:` (2026-10-26, инкремент «2.4-формы»): все формы,
  где оракул пишет `model:`, переведены с `url:`+`scope:` на модель —
  accounts/edit ×4 (`action="/account.<id>"` байт-в-байт), bots new/edit,
  accounts/users/_user, custom_styles/edit (form.text_area), first_runs,
  joins, messages/edit (обе формы), messages/boosts/new
  (`model: [@message, Boost.new]` → polymorphic `/messages/<id>/boosts`),
  rooms/_form + directs/new (`model: room` → `/rooms/<sti>/<id>` через
  `Room#form_scope/form_model_name` — STI-нормализация обеих орфографий
  type, как у `#dom_id`), profile_form_with. Поддержка шардов:
  `FormModel` на `ActiveRecord::Base` (active_record_cr 0.1.22-WIP:
  form_scope/form_model_name из ActiveModel::Naming, form_attributes из
  attributes-хеша через virtual-dispatch стаб), `form_models` в
  action_view_cr структурно по `Array` (инвариантность дженериков:
  литерал `[message, Boost.new]` типизируется `Array(Message | Boost)` и
  не матчится с `when Array(FormModel)`) + расширенные сигнатуры
  `model : FormModel | Array`; action_pack_cr: нейминг REST-маршрутов как
  в Rails (create/update/destroy зовут collection/member-имена — раньше
  неименованные) + опциональный `(.:format)`-сегмент: матчинг
  `/account.<id>` (латентный 404 сабмита account-форм закрыт) и
  dotted-append остаточных позиционных аргументов в path_for. Роуты-имена:
  `join`, `user_profile` (patch), `account_user` (patch/destroy).
  Явные `value:` у полей убраны — значения идут из модели, nil → атрибут
  опускается (семантика Rails TextField). Проверено: все экраны 200,
  байты action/scope/_method, живой PATCH-сабмит `/account.1` → 302.
- [x] `composer_form_tag`/`rich_text_area` + `content_for :footer`
  (2026-10-26, инкремент «2.4-lexxy»): FormBuilder#rich_text_area +
  rich_textarea_tag — action_view_cr **v0.1.21** (`<lexxy-editor>`,
  class-дефолт lexxy-content, name/id из скоупа, явный `value:` бьёт
  атрибут модели, data-direct-upload-url/blob-url-template —
  переопределяемые rich_text_direct_upload_url/rich_text_blob_url_template
  хост-контекста). Adopted: rooms/show/_composer.html.erb вербатим с
  оракулом (content_for :footer, form_with через composer_form_tag,
  form.rich_text_area с mention_prompt_tag; ChatERB включает
  ActionView::Helpers umbrella + FormHelper), messages/edit —
  form.rich_text_area (value: body.to_s — editable_body-трансформация
  аттачментов не портирована, notes/known-gaps.md). Новые хелперы:
  app/helpers/rich_text_helper.cr (1:1 rich_text_helper.rb), 1:1
  drop_target_helper.cr; роут `as: "autocompletable_users"`;
  RichTextHelper глобально wired (helper :rich_text). Диффы рендера
  композера до/после — только порядок атрибутов (сортировка харнесса) и
  пробелы, новая версия байт-точнее к Rails (`value=""` у hidden_field,
  отступы перед закрывающими тегами).
- [x] `button_to` блоком/`method: :delete` — все ручные `<form
  class="button_to">` переведены на шардовый `button_to` (2026-10-25);
  байты — insertion-порядок сырого гема (см. notes/style-parity.md:
  артефакты харнесса сортируют атрибуты, не гнаться за ними). Хвост
  «2 ручные формы ChatLayout» закрыт (2026-10-27, инкремент 1.4):
  join_code — `button_to account_join_code_path` (роут `as:
  account_join_code`) + invite-секция edit через `render partial:
  "accounts/invite"` как у оракула; boost — quick-boost hidden-инпуты
  `_actions` через `hidden_field_tag` (action_view_cr: gating
  `remove_hidden_field_autocomplete`, oracle ft_hidden_no_ac),
  FragmentCache RENDER_VERSION s2→s3.
- [~] `content_for :nav/:footer` — точечно; основной механизм
  `page_open`/`page_close`; `@page_title`/`@body_class` — нет (механизм
  есть в rooms/layouts — render layout: c `@page_title`/content_for;
  перевод остальных ~14 экранов = переиндексация каждого хелпера
  page_open на чтение ivar/content_for, вместе с переносом nav-хелперов
  в ERB — следующий инкремент 2.4/3).
- [~] `render partial:, collection:, as: :user`; `dom_id(@room, :list)` —
  отложено в фазу 3: сайдбар/профили собираются compile-time (ChatERB/
  ChatLayout, SidebarDirect), перевод на collection-рендер = разбор
  мега-хелперов; dom_id(record, prefix) в шарде есть, но STI-записи порта —
  класс Room (class.name ≠ Rooms::Open), остаются порт-хелперы
  Room#dom_id/ChatERB#dom_id (2026-10-25, notes/style-parity.md).

### 2.5. action_cable_cr — каналы (5–6 файлов)
- [x] `on_subscribe :present, unless: :subscription_rejected?` /
  `on_unsubscribe` — presence_channel 1:1.
- [x] `broadcast_to` kwargs + `current_user.slice(...)` — action_cable_cr
  v0.1.5 (kwargs-форма + per-type JSON-эмиттер), `Base#slice` —
  active_record_cr v0.1.18; typing_notifications 1:1, `current_user` в
  каналах (2026-10-25).
- [x] GlobalID (2026-10-26): `GlobalID.create(record)` → Reference
  (to_s/to_param, round-trip) + Identification на AR::Base (`to_gid`/
  `to_gid_param` переехали из turbo_cr) — active_record_cr **v0.1.21**;
  STI-шов `Room#gid_model_name` вместо ручного `to_gid_param` (байты
  gid неизменны); единое `GlobalID.app` (Turbo.app/ActionCable.gid_app
  убраны — turbo_cr **v0.1.7**); `serialize_broadcasting` →
  `to_gid_param` записи: имена стримов stream_for/broadcast_to
  byte-parity с turbo_stream_from (action_cable_cr **v0.1.6**). Смоук:
  tmp/verify25.cr (worktree); turbo oracle-спек 6/6.

### 2.6. turbo_cr / jbuilder_cr (~10 файлов)
- [x] `turbo_stream.append/remove/replace` — TagBuilder в шарде 1:1;
  все 3 turbo_stream-вьюхи на TagBuilder (2026-10-25, notes/style-parity.md):
  StreamsHelper в ApplicationController, `dom_id(Room, prefix)`-оверлоад,
  by_bots#create — inline TagBuilder.
- [x] jbuilder: `json.cache!` — jbuilder_cr v0.1.1 (объектная форма,
  ключ из cache_key); `json.(obj, :attrs)` — `json.extract!` (синтаксис
  `json.(...)` в Crystal невыразим); url-хелперы `room_message_url(...)`
  вместо `jb_origin + "/rooms/..."` (делегат UrlContext, action_pack_cr
  v0.2.15 — публичный __crails_url_helper). `fresh_user_avatar_url` —
  без `direct`-роутинга (2.7) остаётся ChatLayout-путь (2026-10-25).

### 2.7. railties_cr — конфиги и роутер
- [x] Вложенный роутер: `scope module:` есть; `on: :collection` — было
  в action_pack_cr (resources-блоки), verb-макросы принимают Symbol
  (0.2.16); `direct :fresh_account_logo` / `direct :fresh_user_avatar`
  + top-level `route_for` — action_pack_cr v0.2.16 (2026-10-26):
  макрос `direct` (тип модельного аргумента явный:
  `direct :fresh_user_avatar, User do |user, options|`), диспетчеризация
  из `__crails_url_helper`, generic-`DirectArgBox` (Reference в юнионах
  Crystal недекларируем), query-nil пропускаются. Adopted: routes.cr
  1:1 (direct-блоки, `as:` на logo/avatar роутах, блочные searches),
  обёртки fresh_* удалены, jbuilder-делегаты `JbuilderTemplate#fresh_*`
  (notes/style-parity.md, инкремент 2026-10-26). Компромиссы: один
  позиционный аргумент; снапшотный hot-path аватаров — ChatLayout.
- [x] `configure do ... end` для config/environments/*.cr — railties_cr
  v0.1.16 (`configure do |config|`), оба окружения переведены (2026-10-25).
- [x] ActiveJob + GlobalID-сериализация аргументов — `serialized`-макрос,
  `_aj_globalid`, джобы принимают записи (компромиссы — notes).

### 2.8. privates.cr — Ruby-стиль `private`-секций (вместо `private def`)

- [ ] Подключить шард `privates` (~/myshards/privates, v0.1.0): compile-time
  макрос `privates do ... end` разворачивает каждый `def` блока в тот же AST,
  что hand-written `private def` (без рантайм-обвязки); `def self.foo`
  тоже работает. Закрывает пункт «`private def` вместо `private`-секции»
  из класса b (неизбежный Crystal) — вычёркиваем его оттуда.
  Остаточное отклонение: bare `private` — ключевое слово Crystal, имя макроса
  `privates` + ` do`/`end`-обёртка (у оракула секции без обёртки);
  фиксировано в notes/style-parity.md.
  Порядок работ (регламент AGENTS.md):
  1. Подключить локально (path/git), смоук на 2–3 классах (контроллер +
     модель + concern-reopen): сборка, вызов приватного метода снаружи —
     compile error, twinshot review default без дельт.
  2. Опубликовать из ~/myshards/privates (версия уже 0.1.0 — bump не нужен
     при первой публикации), пин в shard.yml, shards update.
  3. Механическая конверсия по файлам (лучше отдельным инкрементом после
     фазы 3, чтобы не плодить конфликты в ChatLayout-разборке): группы
     подряд идущих `private def` → `privates do ... end`; единичные
     `private def` между публичными методами остаются как есть (перенос
     вверх/вниз ради секции — лишний диф).
  4. `rake build:crails` + `twinshot review default` после каждого пучка.

---

## Фаза 3. Архитектурное выравнивание (после фаз 1–2)

- [~] Разобрать мега-хелперы (`ChatLayout`, `messages_page_html`,
  `compile_partials`) обратно в ERB-партиалы оракула — начато (layouts/
  _lightbox.html.erb, инкремент 1; clipboard/qr_code-хелперы);
  инкремент 2 (2026-10-26): accounts/_invite.html.erb — invite-секция
  system_welcome через render(partial:), web_share_session_button →
  ClipboardHelper; маппинг «oracle-путь → генератор» в комментариях
  chat_layout.cr. Инкремент 3 (2026-10-26): messages/boosts/_boosts +
  _boost — ERB-партиалы на BoostEntry-снапшотах через render partial:
  collection: (контекст-класс BoostsERB по образцу ChatERB; ChatLayout
  .boosts_dom/.boost_dom — делегаты, BoostEntry получил message_id;
  FragmentCache::RENDER_VERSION s1→s2). Байты — сырой оракул-эталон
  (rails_oracle_boosts_full.html): button_to form class→method→action,
  _method-инпут type→name→value, `<img ... />` через image_tag;
  DOM-эквивалент со старой версией подтверждён до/после. Инкремент 4
  (2026-10-26, финал review default): последний структурный диф-хвост —
  `_invite`-хвост `<% end %><% end %>  </div>` (текстовый узел `  `
  оракула между `</form>` и `</div>`) и hidden_field nil → без `value`
  (action_view.cr v0.1.23); аватарные webp-варнинги — soft_check
  (twinshot.yml), rationale в notes/style-parity.md. review default:
  129/129 структура, 0 png-фейлов. Инкремент 5 (2026-10-26):
  messages/_message + _actions + _presentation + _unrenderable —
  message_dom/message_actions/presentation_dom разобраны на ERB-партиалы
  (контекст-класс MessagesERB по образцу BoostsERB: locals =
  message + room/creator/attachment/boosts-снапшоты, presentation и
  message--emoji вычисляются в контексте; ChatLayout.message_dom —
  делегат, ручной message_actions удалён). Байты: cmp до/после
  идентичен на 300 сообщениях bench.sqlite3 (бусты/вложения покрыты),
  RENDER_VERSION не менялся. image_tag-иконки: kwargs aria: перед
  class: (AssetTagHelper мерджит остаток в порядке вставки, а байты
  оракула держат aria-hidden до class). Инкремент 6 (2026-10-27,
  «1.4 — последние 2 формы»): quick-boost hidden-инпуты _actions →
  `hidden_field_tag "boost[content]", character` (оракул-байты
  `<input type="hidden" name id value />` без autocomplete; патч шарда:
  hidden_field_tag уважает remove_hidden_field_autocomplete, кейс
  ft_hidden_no_ac против гема 8.1.4, публикация — в хвосте фазы 7);
  join_code → `button_to account_join_code_path` (роут `as:
  "account_join_code"`), invite-секция accounts/edit — `render partial:
  "accounts/invite"` вместо инлайн-дубля (сирота `@qr_path` и обёртка
  `AccountsHelper#copy_button` удалены). RENDER_VERSION s2→s3
  (self-closing ` />` у quick-boost инпутов). Смоук: /account/edit 200,
  POST /account/join_code → 302 + регенерация кода; _boost-форма
  байт-инвариантна. Инкремент 7 (2026-10-27, «1.3 — collection-рендер»):
  messages/index, searches/index и rooms/refreshes/show.turbo_stream
  рендерят `render partial: "messages/message", collection:, cached:
  true` (MessagesHelper/SearchesHelper/RoomsHelper — типизированные
  render-оверлоады поверх ChatLayout.messages_html; cached-лямбда
  оракула → epoch-keyed FragmentCache, `cached:` держит форму вызова);
  `messages_page_html` удалён. Сайдбар: users/sidebars/_show.html.erb
  на партиалах rooms/_direct (collection, as_local: "membership",
  cached: true — локал union `Membership | SidebarDirect` через alias
  SidebarDirectLocal: broadcast-путь рендерит Membership, сайдбар —
  batch-снапшот; оверлоады direct_members/unread? по типу локала),
  rooms/_shared (locals room+unread, как оракул — each+render) и
  rooms/_direct_placeholder (collection, as_local: "user"); ChatERB#render
  принимает `cached:` (no-op — сайдбар целиком в ResponseCache);
  SidebarDirect стал {room, unread, members} (epoch_ms вычисляется в
  партиале, как у оракула). Профили: users/profiles/_membership —
  collection ×2 (shared/direct), items —
  Users::ProfilesHelper::MembershipEntry {room, membership}
  (batch-preload; оракул читает membership.room), ручной membership_row
  удалён. Verified: crails-харнесс 72/0/0; twinshot compare — мои
  экраны structure identical (sidebar-fragment, sidebar
  switched-to-pets, search no-results/empty, профили); 39 структурных
  фейлов прогона — единый паттерн чужого WIP (autocomplete на
  quick-boost инпутах, инкремент 6). Инкремент 8 (2026-10-27, «1.2 — layout-обёртки»):
  layouts/application.html.erb 1:1 с оракулом (плоский исходник; flash-блок
  на ActionController::Flash, csp_meta_tag пустой) — включён глобальный
  layout-механизм action_pack_cr (`__av_layout`/`__render_layout` в
  __default_render). Хелперы layout: ApplicationHelper#
  page_title_tag/current_user_meta_tags/custom_styles_tag/body_classes
  ([@body_class, admin, account-has-logo])/csp_meta_tag + преbuild
  stylesheet_link_tag(:all)/javascript_importmap_tags, новый CableHelper#
  script_aware_action_cable_meta_tag (helper :cable). page_open/page_close
  всех экранов → регистрация (@page_title/@body_class, content_for
  :nav/:footer/:sidebar через page_shell_open/page_shell_close) — рендерят
  пустую строку, оболочку даёт конвейер; ChatLayout.head/body_open/
  page_open/page_close удалены (nav чата → ChatLayout.chat_nav +
  content_for :nav в room_page), _body_close.html.erb удалён.
  Ручные сборки — явный __render_layout: room_page (композер → :footer,
  сайдбар-фрейм → :sidebar, меты чата → :head), rooms new/edit
  (render layout: возвращает только внутренний layout), sidebars#show
  (не-frame ветка), sessions#create/render_rejection, searches#index
  (внутри cache_page), allow_browser (фолбэк __render_layout на
  ApplicationController для abstract-контекста). Реструктурированы под
  оракул шаблоны: welcome/show, sessions/new (@page_title + content_for
  :head, flash из layout: prepare_login(alert:) → flash.now),
  sessions/incompatible_browser (титул в concern AllowBrowser),
  rooms/directs/new, messages/show (мини-обёртка удалена; messages#index
  остаётся без layout — `layout false, only: :index` оракула).
Инкремент 9 (2026-10-27, «1.1 — nav-партиалы/link_to do»):
  nav-хелперы экранов переведены в ERB-партиалы с `link_to do` —
  accounts/_nav, users/_nav (`link_to user_profile_path, class: "btn"
  do`), searches/_recent_searches; устаревшие литеральные `<a>`
  в accounts/users_helper удалены. Дедуп layout-хелперов
  application_helper.cr (двойной набор после параллельного инкремента).
  Патч action_view_cr v0.1.25 опубликован: hidden_field_tag уважает
  remove_hidden_field_autocomplete (8.2-приложения теряли
  `autocomplete="off"` на всех hidden-инпутах — 37 из 39 структурных
  фейлов review были этим). _message.html.erb: восстановлены ведущие
  erb-комментарии + пустая строка оригинала — они дают текстовую ноду
  `\n` перед первым сообщением prepend-страницы истории (watercooler-
  paged диф); body партиала пока плоский/на locals — полный 1:1-текст
  инкрементом позже. Verified: review default 126/129 passed (3 warn —
  soft_check webp-аватары), структура 129/129.
Осталось: полный 1:1-текст вьюх (плоские отступы/locals вместо
  message.room и т.п.) + удаление переходных page_shell_open/close-шимов
  (вьюхи ещё зовут их вместо @page_title/content_for напрямую); bots-вьюхи
  не 1:1 (оракул использует _bot/_form партиалы) — после этого helper :all.
- [x] Убрать двойное именование `Campfire::ResponseCache` /
  `ResponseCache`-алиасы (осталось только полное имя).
- [x] Заменить централизованный `Campfire::ResponseCache.invalidate!` в каждом
  write-экшене на around_action-механику оракула — решено observer-коннектом
  (2026-10-25): epoch читается с выделенного leased-коннекта
  (`DB#checkout` + fiber-семафор), который никогда не пишет, поэтому видит
  собственные коммиты приложения (механика oracle response_cache.rb);
  все 32 ручных invalidate! удалены, все три кэша (Response/Identity/
  Fragment) остаются epoch-keyed и инвалидируются автоматически.
- [x] WriteQueue: сырой SQL (`INSERT INTO webhooks`, `UPDATE ... SET body`)
  перевести на AR-методы после 2.1 — конверсия 2026-10-25 (см.
  notes/style-parity.md): bannable (pluck/compact_blank/bans.create!/
  delete_all/banned!/active!), room#destroy_later (becomes(Rooms::Closed)+
  save!+pluck+delete_all), unread_memberships (visible.disconnected.
  where.not.update_all), message_creator (rich_text через has_rich_text
  body=-сеттера), messages/by_bots update/destroy (body=+save / чистый
  destroy), Room::DestroyJob и RemoveBannedContentJob (find_each(&:destroy));
  поддержка шарда — active_record_cr v0.1.19 (has_rich_text after_destroy,
  CollectionProxy#pluck cast). Остались: FTS-инсерт/апдейт (plain text из
  запроса), Message::Attachment.store, jobs-DB (JobQueue) — вне AR по
  архитектуре (notes).

---

## Не делаем (класс b — неизбежный Crystal)

`private def` вместо `private`-секции — закрывается шардом privates.cr
(план 2.8; имя макроса `privates do`, bare `private` — ключевое слово),
типизированные сигнатуры `: Nil`/`: Room?`,
декларации `@room : Room?`, `require`-бойлерплейт, `.freeze`, subjectless `case`,
`db/schema.yml` vs `schema.rb`, минтест-суита `test/**` оракула, puma/resque-конфиги.
Фиксируем отклонения в `notes/known-gaps.md`.

---

## Порядок работ

1. Фаза 1 целиком (быстрый выигрыш, ~40 файлов) → `twinshot review default`.
2. 2.1 ассоциации + find/rescue (максимум строк диффа) → патч шарда по регламенту.
3. 2.2 → 2.3 (head, respond_to, stale?) → 2.4 (image_tag → form_with → button_to).
4. 2.5 → 2.6 → 2.7.
5. Фаза 3 по файлам, после стабилизации 1–2.
6. После каждой фазы: `twinshot review default`, `rake build:crails`; выполненные
   фазы — в `plans/completed/`.

## Критерий готовности

`twinshot review code`: фейлы только класса (b) (типизация/`private def`/`require`)
и осознанные отклонения из `notes/known-gaps.md`; warnings structure-parity — без
лишних файлов порта.
