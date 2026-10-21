# THIN_CONTROLLERS_REFACTORING — тонкие контроллеры как в оракуле

> СТАТУС: выполнен полностью (2026-10-22). Все этапы верифицированы
> (baseline-бинарь vs новый: побайтово идентичные ответы; twinshot review
> default 128/129 на каждом этапе, warn — известный soft_check
> custom-boost.png).
>
> - Этап 0: `ApplicationController#cache_page` (аналог around_action
>   :cache_read_response), `Room#direct?`, scope `Room.visible(user)` +
>   `visible_for`-делегат; sidebars/rooms/messages переведены на
>   `cache_page`.
> - Этап 1: `rooms_controller#show/refresh` — рендер в RoomsHelpers
>   (`room_page`, `refresh_stream`), `find_messages` как в оракуле
>   (378 → 318 строк).
> - Этап 2: `messages#index` → `cache_page` + `find_messages`; turbo-stream
>   create — `MessagesHelpers#append_message_stream` (также `by_bots`);
>   `boosts` уже был в форме оракула.
> - Этап 3: `accounts/bots` — scope'ы `ordered`/`without_directs` вместо
>   сырых where + актуализирован устаревший комментарий про scope-чейнинг;
>   `logos`/`custom_styles` уже в форме оракула.
> - Этап 4: `searches#show` → `cache_page`; SVG-инициалы аватаров →
>   `AvatarsHelpers#initials_svg` (+ AVATAR_COLORS туда, дубль из
>   контроллера убран); `users`/`sessions`/`autocompletable`/
>   `push_subscriptions`/`rooms/directs` проверены — уже в форме оракула,
>   не тронуты; `active_storage` оставлен (свой стриминг-контракт).

Цель: убрать расхождение с Rails-оригиналом по структуре кода (группа `code`
twinshot: 87 файлов с построчными диффами). Каждый маленький рейлс-контроллер
в порте разросся в 5–10 раз из-за замещения отсутствующих элементов
фреймворка инлайн-кодом. Три источника раздувания:

1. **Инлайн-рендер в контроллерах** — сборка HTML (ChatERB, turbo_frame_tag,
   layout-каркас) вместо тонкого `show` + шаблон/хелпер. Нарушает правило
   AGENTS.md «хелперы — всегда в app/helpers/, никогда в контроллерах».
2. **Копипаста PageCache-логики** — epoch/get/set/send_page повторяется в
   каждом кэшируемом экшене (аналог `around_action :cache_read_response`).
3. **Сырой SQL и class-методы вместо scope'ов** — scope-механика в
   `active_record_cr v0.1.9` уже есть (SCOPES_REFACTORING), но применяется
   неравномерно.

## Принципы (из пилота)

- **Поведение — неприкосновенно**: порождаемый HTML/SQL-семантика не меняется.
  Сортировки, которые сейчас делаются в Crystal (порядок при равных
  `updated_at`), остаются в Crystal — SQL `ORDER BY` его не гарантирует.
- Рендер → `app/helpers/<name>_helpers.cr`, require в `src/app.cr`.
- Данные → scope'ы модели / приватные методы контроллера с именами из
  оракула (`find_direct_placeholder_users`, ...).
- Прямые_ROOMS-детект `rooms.name IS NULL` не дублировать: один метод
  (см. Этап 0).
- Попутно чинятся только N+1 с доказуемо идентичным результатом
  (одним запросом вместо построчных) — как `sidebar_direct_members` в пилоте.

## Протокол верификации каждого этапа (обязателен)

1. `crystal build src/app.cr --release -Dwithout_mt` — чисто.
2. Baseline-бинарь из исходников «до правок» + новый — на одинаковых копиях
   БД (`sqlite3 ... ".backup ..."`), curl ключевых эндпоинтов (полная
   страница + Turbo-Frame фрагмент), `diff` — побайтово идентичны.
   Рецепт пилота: `tmp/sidebar-smoke/` + `tmp/sidebar_smoke_session.cr`.
3. `twinshot review default` — 128/129 (единственный warn — известный
   soft_check custom-boost.png).
4. Фреймворк-шарды не трогаем — патчи шардами не нужны, меняется только
   код app/.

## Этап 0 — общий PageCache-хелпер + `Room#direct?`

Централизовать копипасту кэширования (аналог `around_action
:cache_read_response` оракула) и direct-детект:

- `ApplicationController` (или хелпер `page_cache.cr`): метод обёртки вида
  `cache_page(key) { |page| ... }` — epoch-мемо, get → send_page, рендер
  через блок, set при чистом ответе и неизменном epoch. Перевести на него
  `users/sidebars_controller#show` и `rooms_controller#show` (сверив
  побайтово — тайминги Set-Cookie/epoch не должны измениться).
- `Room#direct? : Bool` (`name.nil?` — с комментом про два написания type) —
  заменить разбросанные `room.name.nil?` / `partition(&.name.nil?)` /
  `WHERE r.name IS NULL` в SQL-комментариях.
- `Room.visible_for` → дополнительно scope `Room.visible(user)` с той же
  семантикой (method сохраняется как делегат, behavior идентичен).

## Этап 1 — `rooms_controller.cr` (378 строк, дифф 391)

Самый заметный в отчёте. По образцу пилота:

- `compile_partials` формы комнаты и рендер new/edit → `RoomsHelpers`
  (модуль уже существует, там лежит `page_open` для форм).
- Данные — через scope'ы (`Room.ordered`, `without_directs`) и приватные
  методы с именами оракула (`set_room`, `find_messages` → при невозможности
  1:1 сохранить имя и семантику).
- PageCache-обёртка из Этапа 0.
- Проверка: комнаты new/edit/show, direct-ветка edit — baseline vs новый.

## Этап 2 — семья messages (messages 302/дифф 325, by_bots 246/268, boosts 134/141)

- `messages_controller#show`: инлайн ChatERB/PageCache → MessagesHelpers
  (ChatERB-модели уже есть) + Этап 0.
- `by_bots_controller`: 5 сырых SQL — перевести на scope'ы Message/User
  там, где SQL генерируется эквивалентный, иначе оставить запрос, но
  вынести из контроллера в модель (private self-метод с именем из оракула).
- `boosts_controller`: рендер → BoostsHelpers.
- Проверка: страница комнаты с сообщениями, бот-сообщение, boosts/new
  (артефакты twinshot: messaging/*, pings/*).

## Этап 3 — accounts-семья (bots 142/139, logos 84/102, custom_styles)

- Рендер форм/страниц → AccountsHelpers/BotsHelpers (существуют).
- Сырые SQL-запросы → scope'ы/модели.
- Проверка: bots list/new, logo upload flow, custom styles.

## Этап 4 — хвост по тому же шаблону

По убыванию диффа, механически: `users/avatars` (162/169),
`users/push_subscriptions`, `rooms/directs` (121/130),
`searches` (108/121), `users`, `sessions`, `autocompletable/users`,
`active_storage` (192 строки — там свой контракт стриминга, аккуратно),
`application_controller` (149/151 — после Этапа 0 станет короче сам).

## Чего НЕ делаем (осознанные ограничения)

- Не переводим сортировки сайдбара/комнат на SQL ORDER BY (риск порядка при
  равных timestamp).
- Не трогаем `default_scope` (шард поддерживает только одиночный where —
  лишнее).
- Не переименовываем и не «улучшаем» публичные контракты — только форма,
  идентичная оракулу.
- Каждый этап — отдельный коммит после зелёной верификации; план по
  завершении перенести в `plans/completed/`.
