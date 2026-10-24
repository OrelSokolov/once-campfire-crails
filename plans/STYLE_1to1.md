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
  Осталось: заменить ручные nil-проверки на `find` в ~10 контроллерах.
- [ ] Callbacks DSL: `before_create`, `after_save, if:`, `after_create_commit`,
  `after_destroy_commit`, `after_save_commit ... if type_previously_changed?(to:)`
  + dirty-API (`*_previously_changed?`) (~10 файлов моделей).
- [ ] `enum` c `prefix:`, `default:` и предикатами: `administrator?`, `banned?`,
  `active?` вместо `role == 1`, `status == 2` (~6 файлов).
- [ ] `belongs_to ... default: -> { Current.user }` (message, boost, room).
- [ ] `has_many ... dependent: :delete_all/:destroy` (+ extension-блоки).
- [ ] Query API: `where.not(hash)`, `order(LOWER(name))`, scopes, `.merge`, `.or`,
  `joins(:assoc)`, `pluck`, `update_all`, `insert_all`, `find_each`, `excluding`.
- [ ] `signed_id(purpose:)` / `find_signed!` / `find_signed` (user/avatar,
  user/transferable).
- [ ] `has_secure_token`, `has_secure_password` + `authenticate_by`.
- [ ] `validates presence:` + `validate` + `errors.add` (push/subscription).
- [ ] STI-нормализация type: `WHERE type IN ('Open', 'Rooms::Open')` → одно имя.
- [ ] `ActiveRecord::Migration[7.2]`-версии (пустой модуль-версия, 11 миграций);
  `t.references` без явного `type: :integer` (вывод из PK, 3 файла).

### 2.2. active_support_cr — мелкие методы (~10 файлов)
- [ ] `presence`, `blank?`, `present?` для `String?`/Parameters.
- [ ] `Time.current`, `to_f`, `to_fs(:epoch|:number)` у Time.
- [ ] `in?`, `many?`, `to_sentence`, `compact_blank`, `.inquiry`.
- [ ] `SecureRandom.alphanumeric`.

### 2.3. action_pack_cr — контроллерный DSL
- [ ] `head :no_content` / `head :forbidden` (стабильный, не сбрасывает статус).
- [ ] `respond_to do |format|`.
- [ ] `stale?(etag:)`, `expires_in ... public:, stale_while_revalidate:`,
  `fresh_when` (logos, avatars, qr_code).
- [ ] `params.require(:x).permit(...)` — strong parameters.
- [ ] DSL `allow_unauthenticated_access(**options)` / `allow_bot_access` через
  class_methods concern'а вместо `skip_before_action` (~8 файлов).
- [ ] `around_action` (для `cache_read_response`) + `before_action, if:/unless:`.
- [ ] `cookies.signed.permanent[...] = { value:, httponly: }`.

### 2.4. action_view_cr — вьюхи (~20 файлов)
- [ ] `image_tag "x.svg", size: 20, aria: { hidden: "true" }` →
  `<img aria-hidden width height>`; убрать кастомный `icon()`.
- [ ] `form_with model: @account, method: :patch` (авто-URL из модели/роутов,
  авто-scope) (~10 файлов).
- [ ] `button_to` с блоком, `method: :delete`, скрытым `_method` (~12 файлов);
  `link_to ... do`.
- [ ] `content_for :nav/:footer/:sidebar` + `@page_title`/`@body_class` вместо
  `page_open`/`page_close`.
- [ ] `render partial:, collection:, as: :user`.
- [ ] `dom_id(@room, :list)`.
- [ ] Порядок атрибутов в тег-билдере как у Rails (href последним в `link_to` и
  т.п.) — сейчас часть хелперов переписана вручную ради byte-parity.

### 2.5. action_cable_cr — каналы (5–6 файлов)
- [ ] `on_subscribe :present, unless: :subscription_rejected?` /
  `on_unsubscribe` (callback-DSL).
- [ ] `broadcast_to @room, action: :start, user: current_user.slice(...)`
  (kwargs + slice).
- [ ] GlobalID: `GlobalID.create/locate`, `to_gid_param`,
  `Locator.locate(gid, only: Room)` — убрать ручной `Base64.urlsafe_encode("gid://...")`.

### 2.6. turbo_cr / jbuilder_cr (~10 файлов)
- [ ] `turbo_stream.append/remove/replace` (3 turbo_stream-вьюхи).
- [ ] jbuilder: `json.cache!`, `json.(obj, :attrs)`, url-хелперы вместо
  `jb_origin + "/rooms/..."`.

### 2.7. railties_cr — конфиги и роутер
- [ ] Вложенный роутер: `resource :session do scope module: ... end`,
  `on: :collection`, `direct :fresh_account_logo`.
- [ ] `configure do ... end` для config/environments/*.cr.
- [ ] ActiveJob + GlobalID-сериализация аргументов (`def perform(room, message)`
  с записями вместо `JSON::Any` + ручной разбор, 6 джобов) — active_job_cr.

---

## Фаза 3. Архитектурное выравнивание (после фаз 1–2)

- [ ] Разобрать мега-хелперы (`ChatLayout`, `messages_page_html`,
  `compile_partials`) обратно в ERB-партиалы оракула (~35 пропавших партиалов:
  `_message`, `_boost`, `accounts/bots/_bot`, `rooms/layouts/*`,
  `layouts/application` и др.).
- [ ] Убрать двойное именование `Campfire::ResponseCache` /
  `ResponseCache`-алиасы.
- [ ] Заменить централизованный `Campfire::ResponseCache.invalidate!` в каждом
  write-экшене на around_action-механику оракула.
- [ ] WriteQueue: сырой SQL (`INSERT INTO webhooks`, `UPDATE ... SET body`)
  перевести на AR-методы после 2.1.

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
