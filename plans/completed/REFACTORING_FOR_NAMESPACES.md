# План: неймспейсы контроллеров (паритет с Rails)

Цель — привести структуру контроллеров порта к Rails-оригиналу
(`once-campfire/app/controllers/**`): подпапки + модули
(`Rooms::OpensController` и т.п.) вместо плоских классов.

Фреймворк неймспейсы уже поддерживает, менять шард для базового случая не нужно:

- `ActionController::Dispatch.resolve` (`lib/action_pack_cr/src/base.cr:715`)
  строит ключ `"rooms/opens"` из `Rooms::OpensController` на этапе компиляции;
- загрузка — рекурсивным `require "../app/controllers/**"`;
- в DSL роутинга есть `scope` и `namespace` (`lib/action_pack_cr/src/routes.cr:116,136`).

Плоская структура — осознанное упрощение порта (см. шапку `config/routes.cr`),
а не ограничение CRails. Этот план устраняет упрощение.

Принцип: HTTP-API (URL-ы, ответы) не меняются вообще — меняются только
расположение файлов, имена классов и строки `to:`/`controller:` в роутах.
Каждую стадию проверяем паритетом с Rails-оракулом.

---

## Стадия 1 — неймспейсы 1:1 (без слияния/разделения классов)

Контроллеры порта, которые в Rails лежат в подпапках и в порту существуют
отдельным файлом. Переносим как есть, меняем имя класса и роут.

| Файл порта (сейчас) | Стало | Класс | Роуты (`to:`/`controller:`) |
|---|---|---|---|
| `session_transfers_controller.cr` | `sessions/transfers_controller.cr` | `Sessions::TransfersController` | `"sessions/transfers#show"` / `#create` |
| `avatars_controller.cr` | `users/avatars_controller.cr` | `Users::AvatarsController` | `"users/avatars#show"` |
| `profiles_controller.cr` | `users/profiles_controller.cr` | `Users::ProfilesController` | `"users/profiles#show"` / `#update` |
| `sidebars_controller.cr` | `users/sidebars_controller.cr` | `Users::SidebarsController` | `"users/sidebars#show"` |
| `autocompletable_users_controller.cr` | `autocompletable/users_controller.cr` | `Autocompletable::UsersController` | `"autocompletable/users#show"` |
| `bots_controller.cr` | `accounts/bots_controller.cr` | `Accounts::BotsController` | `resources :bots` внутри `scope module: "accounts"` |
| `custom_styles_controller.cr` | `accounts/custom_styles_controller.cr` | `Accounts::CustomStylesController` | аналогично |
| `logos_controller.cr` | `accounts/logos_controller.cr` | `Accounts::LogosController` | аналогично |
| `directs_controller.cr` | `rooms/directs_controller.cr` | `Rooms::DirectsController` | `resources :directs` в `scope path: "rooms"` |

Остаются плоскими (в Rails тоже плоские или port-specific):
`accounts`, `application`, `first_runs`, `joins`, `messages`, `pwa`,
`qr_codes`, `rooms`, `searches`, `sessions`, `users`, `welcome`, `up`,
`active_storage` (port-specific, в Rails — внутренность Rails),
`boosts` и `session-`власти — см. стадию 2.

Шаги:

1. Создать модули-обёртки. В Crystal файл `sessions/transfers_controller.cr`
   должен объявлять `class Sessions::TransfersController` — модуль
   `Sessions` можно не объявлять явно (Crystal создаст неявно), но для
   единообразия с Rails допускается явный `module Sessions; end` в файле
   неймспейса. Решить один вариант и придерживаться.
2. `git mv` файлов в подпапки, переименовать классы, поправить
   `super`-вызовы/ссылки на типы внутри (если есть).
3. Обновить `config/routes.cr`:
   - `scope path: "session"` → `scope path: "session", module: "sessions"`
     (если `module:` в `scope` не поддержан — см. «Изменения фреймворка»);
   - `/users/me/...` и `/users/:token/avatar` → строки
     `"users/sidebars#show"`, `"users/profiles#..."`, `"users/avatars#show"`;
   - `/autocompletable/users` → `"autocompletable/users#show"`;
   - блок `resource :account` → обернуть вложенное в `scope module: "accounts"`
     и убрать `controller: "custom_styles"`-костыли;
   - `resources :directs` → оставить в `scope path: "rooms"`, добавить
     `module: "rooms"`.
4. Перенести view-директории под новые controller path (lookup views идёт
   по пути контроллера):
   - `app/views/profiles` → `app/views/users/profiles`
   - `app/views/sidebars…`/`users/sidebars` — уже на месте, проверить
   - `app/views/bots` → `app/views/accounts/bots`
   - `app/views/custom_styles` → `app/views/accounts/custom_styles`
   - `app/views/session_transfers` → `app/views/sessions/transfers`
   - `app/views/autocompletable_users` → `app/views/autocompletable/users`
   - `app/views/directs` → `app/views/rooms/directs`
   - partial-ссылки (`render partial:`), `redirect_to ..._path` и
     именованные роуты не должны измениться (имена роутов не трогаем).
5. Глобольно проверить ссылки на переименованные классы:
   `grep -rn "AvatarsController\|ProfilesController\|..." app/ src/ lib/ config/`
   (в т.ч. `controller_helpers`, тесты, `tmp/verify_*` скрипты при необходимости).

## Стадия 2 — разделение слитых контроллеров (полный паритет)

Вторая группа отличий (см. шапку `config/routes.cr`): порт слил несколько
Rails-контроллеров в один. Для полного паритета структуры — разделить:

### 2.1. Виды комнат

Порт: один `RoomsController` с `defaults: {kind: ...}`.
Rails: `Rooms::OpensController`, `Rooms::ClosedsController`,
`Rooms::DirectsController` (`namespace :rooms`).

- Вынести `new/create/edit/update` для opens/closeds в
  `Rooms::OpensController` / `Rooms::ClosedsController`
  (общая логика — в общий `Rooms::BaseController < ApplicationController`
  или в `RoomsController`, как в Rails: там наследование от
  `RoomsController`? — сверить с Rails-исходниками при реализации).
- В `routes.cr` заменить `scope path: "rooms", as: "rooms"` + `controller: "rooms"`
  на `namespace :rooms` с обычными `resources :opens/:closeds/:directs`.
- Views: `app/views/rooms/{opens,closeds}` (в порту сейчас, вероятно,
  общие шаблоны в `app/views/rooms` — разложить по видам, как в Rails).

### 2.2. Messages::ByBots и Messages::Boosts::ByBots

Порт: `bot_create/bot_index/bot_show` внутри `MessagesController`,
`boosts#bot_create` внутри `BoostsController`.
Rails: `Messages::ByBotsController`, `Messages::Boosts::ByBotsController`.

- Вынести в `messages/by_bots_controller.cr`,
  `messages/boosts/by_bots_controller.cr`.
- Роуты: `controller: "messages/by_bots"`, `"messages/boosts/by_bots"`.
- `BoostsController` → `Messages::BoostsController`
  (`messages/boosts_controller.cr`).

### 2.3. Rooms::Involvements, Rooms::Refreshes (опционально)

Rails держит `rooms/involvements_controller.rb`, `rooms/refreshes_controller.rb`;
порт — экшены `rooms#refresh`, `rooms#involvement`, `rooms#update_involvement`.
Разделить, если хотим полного паритета; view-директории
`rooms/involvements` уже есть.

Опционально потому, что это уже не «плоскость», а слияние экшенов —
решить отдельно, стоит ли шевлить.

**Решение (2026-10-17): отложено.** Оба экшена рендерятся через
ChatERB-контекст (`compile_template "involvement_show"` в chat_erb.cr),
а не implicit-render'ом контроллера; разделение создаёт тот же конфликт
шаблонов, что и у сайдбара (файл по пути `<dir>/<action>.html.erb`
компилируется и в контекст контроллера, где нет локалов ChatERB) —
потребуется переименование в `_show.html.erb` и правка chat_erb.cr.
Смысла в HTTP-паритете это не добавляет — оставлено как есть.

## Статус выполнения (2026-10-17)

- Стадия 1 — выполнена полностью (9 контроллеров + view-директории +
  строки роутов; jbuilder-реестр в `src/app.cr` обновлён).
- Стадия 2.1 — выполнена: `Rooms::OpensController`/`Rooms::ClosedsController`
  (общее — в базовом `RoomsController`: `create_room`/`update_room`/
  `prepare_room_form`), direct-ветка edit — в `Rooms::DirectsController#edit`
  (шаблонный хелпер `head` переименован в `page_head`, чтобы не перекрывать
  фреймворковый `head(status)`). Роуты — `namespace :rooms`. Вьюхи
  new/edit разложены по `rooms/{opens,closeds}`, directs/edit выделен;
  `_form.html.erb` остался один общий (`rooms/_form.html.erb`, locals
  `kind`/`is_open`) — дублировать 100+ строк на вид комнат смысла нет.
- Стадия 2.2 — выполнена: `Messages::ByBotsController`,
  `Messages::BoostsController`, `Messages::Boosts::ByBotsController`;
  вьюхи — `messages/by_bots/`, `messages/boosts/`,
  `messages/boosts/by_bots/`.
- Сайдбар: `users/sidebars/show.html.erb` → `_show.html.erb` — файл
  компилируется только в контексте ChatERB с локалами; после неймспейса
  контроллера имя без подчёркивания попадало бы и в implicit-scan
  экшена `Users::SidebarsController#show`, где локалов нет.
- Проверки: `rake build:crails` чистый; таблица роутов отличается от
  исходной только колонкой Controller#Action (URL/глаголы/имена не
  изменились); capybara-сьют 72/0, HTML-артефакты побайтово идентичны
  прогону до рефакторинга (PNG-диффы — только пер-процессный сид
  `String#hash` в цвете аватар-инициалов).
- Изменений фреймворка не потребовалось: `scope module:` и view lookup
  по неймспейс-пути уже поддержаны.

## Изменения фреймворка (только если понадобятся)

Перед стартом проверить, и при отсутствии — добавить по процедуре из
`AGENTS.md` (локальный шард → патч в `~/myshards/` → bump версии →
подтянуть в проект → `rake build:crails`):

1. `scope module: "..."` — поддержка опции `module` в `scope`
   (`lib/action_pack_cr/src/routes.cr:116`). `namespace` есть, но Rails
   в `routes.rb` использует в основном `scope module:`; для зеркальности
   роут-файла нужна именно она.
2. View lookup по неймспейс-пути контроллера — убедиться, что
   `Users::AvatarsController` ищет `app/views/users/avatars/*`
   (вероятно, работает через тот же key, что и `resolve`; проверить
   тестом на одном контроллере до массового переноса).
3. `direct :fresh_account_logo` / `direct :fresh_user_avatar` —
   используются ли портом; если нет, вне скоупа этого плана.

## Порядок работ и проверки

1. Стадия 1 одним коммитом (или по неймспейсу на коммит:
   `users/*`, `accounts/*`, `sessions/*`, `rooms/directs`,
   `autocompletable/users`).
2. После каждого шага:
   - `rake build:crails` — сборка без ошибок;
   - `bin/crails routes` (или аналог) — дифф списка роутов с Rails
     (`once-campfire/bin/rails routes`); URL-ы и имена не должны измениться;
   - smoke существующими скриптами (`script/smoke_*.cr`) и
     `capybara-tests/run.rb`;
   - паритет ответов с Rails-оракулом (тулing в `tmp/parity_report.py`,
     `tmp/rails_oracle_*.html`) по затронутым эндпоинтам:
     `/session/transfers/*`, `/users/me/*`, `/users/:token/avatar`,
     `/autocompletable/users`, `/account/**`, `/rooms/opens|closeds|directs/**`,
     `/rooms/:id/:bot_key/**`, `/messages/*/boosts`.
3. Стадия 2 после стабилизации стадии 1; для 2.1 обязательно сверить
   поведение `kind`-специфики (порт читает `defaults`) с Rails-версиями
   контроллеров — это единственное место, где рефакторинг меняет код
   экшенов, а не только расположение.
4. Обновить комментарии:
   - шапку `config/routes.cr` (описывает старую плоскую структуру);
   - `CRAILS_REMAINING.md` / `PLAN_REMAINING.md`, если ссылаются на
     плоские имена контроллеров.

## Риск и откат

- Изменения чисто структурные + строки роутов; откат — revert коммитов.
- Главный риск — пропущенные строковые ссылки `"avatars#show"`-типа в
  роутах/тестах/скриптах: они не ловятся компилятором. Покрывается
  grep-проходом (шаг 5 стадии 1) и диффом таблицы роутов.
- Стадия 2.1 трогает логику экшенов — обязательный паритет-тест
  `/rooms/opens|closeds` (new/create/edit/update) до и после.
