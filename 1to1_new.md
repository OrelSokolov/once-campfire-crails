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

## Фаза 3 — тяжёлые патчи фреймворка (НАЧАТА 2026-10-24)

- [x] **action_pack.cr 0.2.13**: multipart file params — файловые части →
      `ActionController::UploadedFile` в params (ActionDispatch::Http::
      UploadedFile semantics; `Parameters::Value` расширен, permit пропускает
      файлы как скаляры; спека spec/multipart_spec.cr, полных 181 examples,
      0 failures / 4 pre-existing errors). Приложение: ручной multipart-парсер
      в `MessagesController` удалён (~60 строк), create читает
      `params.require(:message).permit(:body, :attachment, :client_message_id)`;
      capybara 72 runs / 0 failures, compare 2/129 (оба soft_check png).
- [x] **action_pack_cr 0.2.14**: helper wiring — реестр `HELPERS` (маркер
      `include ActionController::Helper` в модуле app/helpers),
      конвенционный авт-include в finished-кодегене (`RoomsController →
      RoomsHelper/RoomsHelpers`, включая абстрактный ApplicationController),
      `helper :sym` / `helper :all` (Rails API), `helper_method` с
      валидацией в конце программы (контекст рендера — сам контроллер,
      поэтому семантически no-op). Приложение: 18 view-хелперов помечены
      маркером, все `include XHelper` убраны из контроллеров (AGENTS.md),
      8 неконвенционных пар объявлены `helper :sym`. Спека
      spec/helper_wiring_spec.cr (3 examples). Ограничение: `helper :all`
      (Rails-дефолт) пока невозможен — 8 конфликтов имён между
      crails-обёртками (page_open/page_close/copy_button/…), у оракула их
      нет; разблокируется после tag-билдера и переноса HTML из ChatLayout.
- [ ] **action_view_cr**: tag-билдер (`tag.figure/span/title`, `tag(:meta, ...)`,
      `link_to ... do` с порядком атрибутов оракула, `image_tag` с вложенными
      `aria: {hidden:}`) → путь к переносу HTML из ChatLayout в ERB-партиалы.
- [x] **active_job_cr** (уровень приложения, без шарда): `ApplicationJob` с
      макросом `serialized(**args)` → `perform_later` / отложенный
      `__queue_pair` / dispatch `__run`; аргументы-записи сериализуются как
      `{"_aj_globalid": ...}` (GlobalID::Locator из active_record 0.1.16),
      примитивы — напрямую; `discard_on`/`discards?` через общий
      `DISCARD_REGISTRY` (class vars в Crystal не шарятся по иерархии) +
      наследование регистраций через `macro inherited`. 5 джоб переписаны на
      инстанс-`perform(record, ...)` 1:1 к оракулу. Kind-строки JobQueue
      ("push"/"webhook"/...) — стабильный контракт (pending-джобы в очередях
      БД). verified: tmp/verify_jobs.cr (7/7).
- [ ] Перенос логики джоб в модели (отдельный пункт): `bot.deliver_webhook`,
      `message.broadcast_unread_room`, `user.remove_banned_content`,
      `room.destroy_one_message_at_a_time` / `reset_remote_connections_of` —
      сейчас логика остаётся в джобах, оракул держит её в моделях.

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
