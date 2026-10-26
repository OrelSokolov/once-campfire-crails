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
- [~] `stale?(etag:)`/`fresh_when` — есть в шарде; `expires_in` — нет;
  logos/cached_responses — ручная механика (ETag/Cache-Control byte-parity).
- [x] `params.require(:x).permit(...)` — символная форма во всех контроллерах.
- [x] DSL `allow_unauthenticated_access(**options)` / `allow_bot_access` —
  макросы в concerns/authentication.cr 1:1 с class_methods оракула
  (2026-10-25), ~10 контроллеров переведены; добавлен `before_action
  :deny_bots` (порт-эквивалент через bot_request? — authenticated_by-трекинга
  нет); by_bots сохраняет порт-специфичный skip require_authentication
  (require_bot). Макро-грабли `**options`-проброса — notes/style-parity.md.
- [~] `around_action` + `before_action, if:/unless:` — есть в шарде;
  page-cache в app вручную (cached_responses).
- [~] `cookies.signed.permanent[...] = { value:, httponly: }` — hash-форма
  `[]=` не поддержана; app пишет `cookies.signed.set(...)`.

### 2.4. action_view_cr — вьюхи (~20 файлов)
- [x] `image_tag` — механика есть (пребилд-манифест), `icon()` остаётся
  для byte-parity (notes/style-parity.md).
- [ ] `form_with model:` — отложено (byte-parity URL/скопов форм).
- [x] `button_to` блоком/`method: :delete` — все ручные `<form
  class="button_to">` переведены на шардовый `button_to` (2026-10-25);
  байты — insertion-порядок сырого гема (см. notes/style-parity.md:
  артефакты харнесса сортируют атрибуты, не гнаться за ними). Остались
  2 ручные формы в ChatLayout (статический билдер — фаза 3).
- [~] `content_for :nav/:footer` — точечно; основной механизм
  `page_open`/`page_close`; `@page_title`/`@body_class` — нет.
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
- [~] GlobalID: `Locator.locate(gid, only:)`/`to_gid_param` — есть;
  `Room#to_gid_param` вручную (STI-нормализация), `GlobalID.create` нет.

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
- [~] Вложенный роутер: `scope module:` есть; `on: :collection`,
  `direct :fresh_account_logo` — нет.
- [x] `configure do ... end` для config/environments/*.cr — railties_cr
  v0.1.16 (`configure do |config|`), оба окружения переведены (2026-10-25).
- [x] ActiveJob + GlobalID-сериализация аргументов — `serialized`-макрос,
  `_aj_globalid`, джобы принимают записи (компромиссы — notes).

---

## Фаза 3. Архитектурное выравнивание (после фаз 1–2)

- [~] Разобрать мега-хелперы (`ChatLayout`, `messages_page_html`,
  `compile_partials`) обратно в ERB-партиалы оракула — начато (layouts/
  _lightbox.html.erb, инкремент 1; clipboard/qr_code-хелперы);
  инкремент 2 (2026-10-26): accounts/_invite.html.erb — invite-секция
  system_welcome через render(partial:), web_share_session_button →
  ClipboardHelper; маппинг «oracle-путь → генератор» в комментариях
  chat_layout.cr. Осталось: boost_dom/messages_html (горячий путь
  fragment-кэша — только вместе с коллекционным рендером).
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

`private def` вместо `private`-секции, типизированные сигнатуры `: Nil`/`: Room?`,
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
