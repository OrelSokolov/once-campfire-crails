# План 1:1 parity — по итогам twinshot review code (2026-10-24)

Источник: `twinshot-report/code/report_for_agent.md` (283 fail: 188 txt + 449 structure),
сверено с актуальными шардами в `lib/`. Отдельные пробелы из записок уже закрыты
патчами шардов — фиксируется ниже.

## Фаза 1 — дешёвая чистка (ВЫПОЛНЕНО 2026-10-24)

- [x] `accounts_controller#edit`: scope `visible_to` + `ordered` (SQL ORDER BY
  LOWER(name)) вместо in-memory sort; `visible_to` добавлен в User (оракул
  держит его в User::Bannable — Crystal `scope` только в теле класса).
      verified: tmp/verify_visible_to.cr
- [x] `Model.all.find(str)` — паттерн в коде уже отсутствует; class-level
  `find(String)` в шарде есть (base.cr). Записка в style-parity обновлена.
- [x] Membership `visible`/`unread` → `where.not(...)` (verified:
  tmp/verify_not_scope.cr); scope-ы `connected`/`disconnected` из
  Membership::Connectable оракула добавлены.
- [x] `emoji_helper.cr` висячая запятая убрана.
- [x] `notes/known-gaps.md`: устаревшая запись про order() удалена.

## Фаза 2 — патчи шардов (ВЫПОЛНЕНО 2026-10-24)

Опубликовано по workflow AGENTS.md (myshards → tag vX.Y.Z → push → подтяжка):

- [x] **action_cable.cr 0.1.4**: `on_subscribe`/`on_unsubscribe` (gem's
  Channel::Callbacks, unless-guard) + `subscription_rejected?`; спека
  spec/callbacks_spec.cr (54 examples green). Приложение:
  `PresenceChannel` переписан 1:1 к оракулу; `Membership::Connectable`
  перенесён на инстанс-методы (present/connected/disconnected/
  refresh_connection/increment/decrement + class connect/disconnect_all;
  verified tmp/verify_presence_model.cr).
- [x] **action_pack.cr 0.2.12**: предикаты `request.get?/head?/post?/…`
  (HTTP::Request reopen). Использованы в BlockBannedRequests, public_cache.
  Базовые 4 ошибки спеков pre-existing (baseline идентичен).
- [x] **active_record.cr 0.1.16**: `GlobalID::Locator.locate(gid[, only:])`
  (globalid-lite, STI short-name aware; verified tmp/verify_global_id.cr) +
  виртуальные `find?`/`table_name` стабы на Base для runtime class-объектов.
  Приложение: `RoomMessagesChannel#subscribable_room?` без ручного Base64.
- [x] `shards update`: lock 0.1.4 / 0.2.12 / 0.1.16; lib/ == тегам.
- [x] Current/delegate: делегат в шарде есть, но CurrentAttributes порта —
  только class-level (instance-API не портирован) — остаётся ручной
  `self.request_host` (зафиксировано в known-gaps).
- [x] twinshot review default (compare): 2/129 fail — оба png из soft_check.

## Фаза 3 — тяжёлые патчи фреймворка (НЕ НАЧАТА)

- [ ] **action_pack_cr**: view context + `helper_method` + автоподключение
      `app/helpers/**` → убрать `include XHelper` из контроллеров
      (нарушение AGENTS.md «хелперы никогда в контроллерах»).
- [ ] **action_view_cr**: tag-билдер (`tag.figure/span/title`, `tag(:meta, ...)`,
      `link_to ... do` с порядком атрибутов оракула, `image_tag` с вложенными
      `aria: {hidden:}`) → путь к переносу HTML из ChatLayout в ERB-партиалы.
- [ ] **action_pack_cr**: multipart file params — файловые части → UploadedFile
      в params → убрать ручной парсер в MessagesController.
- [ ] **active_job_cr**: сериализация аргументов-записей (`perform(room,
      message)` через GlobalID) + `discard_on` → джобы 1:1.

## Фаза 4 — средние патчи (НЕ НАЧАТА)

- [ ] `allow_browser versions:` (action_pack_cr) — убрать ручной UA-парсинг
      из concern AllowBrowser.
- [ ] `update!(ActionController::Parameters)` + вложенные settings-хэши.
- [ ] Пагинация `set_page_and_extract_portion_from` / page-скопы.
- [ ] `has_one_attached do |attachable| variants end` + `has_json :settings`.
- [ ] `belongs_to ..., default: -> { Current.user }`.
- [ ] Переименование `*_helpers` → `*_helper` оракула (после view context).

## Уже в плане Phase 7 (notes/style-parity.md) — не дублировать

`Migration[8.1]`, `render layout:` с блоком, `has_many ... do` extension-блоки,
`table_name_prefix`.

## Осознанные отклонения — не трогать

Rails-инфра (bin/*, config/initializers, test/** → capybara-tests, vendor/**),
`joins_controller` flat (express-референс), ChatLayout compile-time для byte-parity
(до закрытия фазы 3), CurrentAttributes class-level-only (см. known-gaps).
