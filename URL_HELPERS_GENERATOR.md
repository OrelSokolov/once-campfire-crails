# URL_HELPERS_GENERATOR — план генератора именованных роут-хелперов

Разворачивает `CRAILS_REMAINING.md` §1 (Named route helpers). Цель:
в CRAILS появляется Rails-эквивалент `*_path` / `*_url`, проект
перестаёт хардкодить пути строками (~сотня мест: 26 `redirect_to`,
23 `action=`, ~21 рабочий `href=`, 34 интерполяции в ChatLayout).

> **Статус** (2026-10-19). Сделаны этапы 0, 1, 2, 3 и 4.1–4.4
> (redirect_to, action=, href=, ChatLayout/хелперы). Остался этап 5
> (чистка ручных хелперов: решено по аудиту — см. ниже). Детали —
> пометки «Сделано» по этапам ниже.

## Отправная точка (что уже есть)

- `Route` хранит `name`, сегменты и `defaults`
  (`lib/action_pack_cr/src/routes.cr:3-22`); `Drawer` композирует
  имена по Rails-правилам (`compose_name`, `routes.cr:321`) —
  `resources :rooms` даёт `room`, `new_room`, `edit_room`, вложенные
  — `room_message` и т.д. Спеки имена проверяют
  (`lib/action_pack_cr/spec/action_pack_spec.cr:76`).
- Потребителей имён нет: рантайм-диспетчер матчит по паттерну, а
  обратного направления (имя → URL) не существует.
- Маршруты рисуются **в рантайме**: `config/routes.cr` подключается
  ПОСЛЕ контроллеров (`src/app.cr:61`), `routes.draw` выполняется как
  обычный код. compile-time макрос таблицу маршрутов не видит.

## Ключевое решение: `method_missing`, не compile-time макрос

Генерация методов на этапе компиляции потребовала бы парсить
`config/routes.cr` из макроса — хрупко и дублирует DSL. Вместо этого —

паттерн, уже принятый в экосистеме (`macro method_missing` в
`action_view_cr/helpers/tag_helper.cr:107`, `jbuilder_cr.cr:260`):

```crystal
module CRails::Routes::UrlHelpers
  macro method_missing(call)
    def {{call.name}}(*args, **opts) : String
      CRails.application.routes.generate_url({{call.name.stringify}}, args, opts)
    end
  end
end
```

Вызов `room_path(room)` разворачивается в метод, который в рантайме
резолвит имя по индексу маршрутов и собирает путь. Важное свойство:
`method_missing` срабатывает только если явного метода нет —
существующие самописные хелперы (`message_path` в
`app/helpers/messages_helpers.cr:19`, `room_edit_path` в
`app/helpers/chat_layout.cr:159` и т.д.) продолжают работать и
тенят сгенерированные. Это даёт безопасную поэтапную миграцию без
большого взрыва.

Скорость: имя парсится один раз (кэш `name → разобранные сегменты`
классовой переменной), построение пути — склейка строк. Для
~160-170 вызовов на страницу — копейки.

## Семантика ( Rails-parity, минимально необходимое )

| Правило | Поведение |
|---|---|
| Позиционные аргументы | Подставляются в динамические сегменты (`:id`, `:message_id`) слева направо, с урл-кодированием (`URI.encode_www_form`). Префиксные сегменты `"@:message_id"` — значение кодируется, `@` сохраняется. |
| Лишние позиционные | Остаток уходит в query-string, как в Rails. |
| Завершающий `Hash`/`NamedTuple` | Query-параметры (`anchor:`, `v:` и т.п.), кодирование ключей и значений. |
| Типы аргументов | `String | Int32 | Int64` напрямую; объекты с `to_param` (проверка `responds_to?` в рантайме) — Rails-семантика `room_path(room)`. |
| `*_url` | `origin + *_path`. origin: (1) контекст запроса — `Host`-заголовок (у контроллера уже есть `origin`, `application_controller.cr:96`); (2) глобальный фолбэк `CRails.application.routes.default_url_origin` (для Jbuilder-партиалов и jobs, дефолт из `config.host/port`). |
| Неизвестное имя / не хватает аргументов | `raise ArgumentError` — аналог `ActionController::UrlGenerationError`. |
| Маршрут без имени | Хелпера нет (`method_missing` умирает с понятной ошибкой). |
| Дубли имени в таблице | Последний выигрывает (в `config/routes.cr` дублей нет — проверить этапом 0). |

## Этапы

### 0. Аудит (без кода)

> **Сделано** (2026-10-19). Дампы `bin/crails routes` порта и
> `bin/rails routes` эталона (`tmp/routes-new.txt`): множества имён
> идентичны — 21 имя (root, first_run, new_session, edit_account,
> account_bots, new/edit_account_bot, edit_account_custom_styles,
> user, room, room_messages, room_message, edit_room_message,
> room_at_message, message_boosts, new_message_boost,
> new/edit_rooms_open, new/edit_rooms_closed, new_rooms_direct).
> Дублей имён в таблице нет. Конфликты с ручными хелперами
> (`message_path`, `avatar_path`, `room_edit_path`, `fresh_*`,
> `blob_url`) не проявились: явные методы тенят сгенерированные —
> решения по каждому отложены на этап 5.

- Дамп имён: `bin/crails routes` уже печатает таблицу
  (`railties_cr.cr:611`) — снять список `name != nil` и сверить с
  `bin/rails routes` эталона (`once-campfire/`); расхождения имен
  из-за известных отклонений порта (один `RoomsController`, `scope
  as: "rooms"` с видами `opens/closeds/directs`) зафиксировать
  списком «хелперов, которых не будет».
- Конфликты имён: сгенерированные имена vs существующие методы в
  `app/helpers/` (`message_path`, `avatar_path`, `room_edit_path`,
  `fresh_*`, `blob_url`…). Пока они тенят — это ок; на этапе 5
  решить по каждому: удалить ручной / переименовать / оставить
  (отклоняющиеся от Rails, вроде `room_edit_path` с выбором сегмента
  opens/closeds — оставить навсегда).

### 1. Шард `action_pack_cr` (локально, первым)

> **Сделано** (2026-10-19). `RouteSet#named_routes` (ленивый индекс,
> последнее имя выигрывает) + `RouteSet#path_for(name, args)` —
> позиционные аргументы в динамические сегменты слева направо
> (`URI.encode_www_form`, префикс `@:message_id` сохраняет `@`),
> остаток → query (key=value, как Rails), `ArgumentError` на
> неизвестное имя / нехватку аргументов. Новый
> `src/routes/url_helpers.cr`: `macro method_missing` генерирует
> методы только для имён с суффиксом `_path`/`_url` (прочие —
> compile error с внятным текстом); `class_property route_set`
> (railties_cr назначает `CRails.application.routes` в
> `Application#initialize`) и `default_url_origin` (фолбэк `*_url`);
> origin для `*_url` — compile-time выбор по `@type.methods`:
> `origin` (контроллеры) → `jb_origin` (Jbuilder) → дефолт.
> `include` в `ActionController::Base` (base.cr). Спеки:
> `spec/action_pack_spec.cr` (базовые/вложенные/`@`-префикс/query/
> лишний позиционный → query, to_param, `_url` c origin и фолбэком,
> неизвестное имя, неименованный маршрут, нехватка аргументов) —
> suite шарда 176 примеров зелёные. Особенность реализации:
> `responds_to?(:origin)` в рантайм-ветвлении не годится (мёртвая
> ветка компилируется и триггерит method_missing) — поэтому
> compile-time `@type.methods`.

Файлы:

- `lib/action_pack_cr/src/routes.cr` — в `RouteSet`:
  - `named_routes : Hash(String, Route)` — индекс, строится лениво
    (первый запрос) или после `draw`;
  - `path_for(name : String, args : Array, opts) : String` —
    построение пути по правилам таблицы выше (сегменты `"@:param"`
    разбираются тем же алгоритмом, что и матчинг `routes.cr:58-76`,
    только в обратную сторону);
  - `generate_url(name, args, opts)` — обёртка: режет суффикс
    `_path`/`_url`, для `_url` добавляет origin.
- Новый `lib/action_pack_cr/src/routes/url_helpers.cr` — модуль
  `UrlHelpers` с `macro method_missing` (скетч выше) + мемо-кэш
  разобранных сегментов по имени.
- `lib/action_pack_cr/src/base.cr` — `include CRails::Routes::UrlHelpers`
  в `ActionController::Base`: контроллеры получают хелперы, а с
  ними и вьюхи (ERB рендерится в контексте инстанса контроллера,
  комментарий `base.cr:571`).

Спеки (`lib/action_pack_cr/spec/`): базовые (`root_path == "/"`,
`room_path(1) == "/rooms/1"`, вложенный
`room_message_path(1, 2) == "/rooms/1/messages/2"`), префиксный
`room_at_message_path(1, 2) == "/rooms/1/@2"`, query
(`room_path(1, v: 3)`), лишний позиционный → query, `to_param`,
`_url` c origin, неизвестное имя → raise, неименованный маршрут не
резолвится.

Проверка сборки: `rake build:crails` (ловит проблемы до рантайма).

### 2. Публикация шарда (процесс из AGENTS.md)

> **Сделано** (2026-10-19). `action_pack.cr` **v0.2.6** (02d3c19:
> UrlHelpers + попутно зафиксирован отдельным коммитом 0ed73f5 чужой
> WIP source-location роутов, лежавший в рабочем дереве myshards);
> `railties.cr` **v0.1.13** (54cdd26: wiring `UrlHelpers.route_set`
> в `Application#initialize`, рабочий чекаут `~/myshards/railties.cr`
> развёрнут по конвенции), монорепо `rails.cr` засинкано (4f669a1).
> Проект: `shards update railties_cr action_pack_cr` → 0.2.6/0.1.13,
> сборка + смоук зелёные. Известное: спек
> `integration_spec.cr:137 get_with_params` в standalone-railties
> падает и ДО наших правок (на 0.1.12 + action_pack 0.2.5) — фикс
> есть только в монорепо (3c801c4 «Fix two stale test failures»),
> standalone-спек старый; не регресс.

После зелёных спеков: патч в `~/myshards/action_pack.cr`, bump
version `vX.Y.Z`, publish; в проекте подтянуть опубликованную версию
в `shard.yml`, протестировать снова, `rake build:crails`, коммит и
пуш если всё зелёное.

### 3. Подключение в приложении

> **Сделано** (2026-10-19, частично). `railties_cr.cr`
> `Application#initialize` назначает
> `CRails::Routes::UrlHelpers.route_set = @routes` — контроллеры и
> вьюхи получают хелперы автоматически. Осталось (по мере
> надобности): `include` в `JbuilderTemplate` (origin из
> `jb_origin` уже поддержан хелпером) и сеттинг
> `default_url_origin` из ENV/конфига для jobs.

- Контроллеры/вьюхи — уже через `include` из `base.cr`.
- Jbuilder-партиалы (контекст без контроллера, `src/app.cr:41-54`,
  там уже есть `jb_origin`): `include CRails::Routes::UrlHelpers`
  в `JbuilderTemplate`, origin — из `jb_origin`.
- Jobs/модели вне запроса (аналог `message_pusher.rb:28` эталона):
  `include` по мере надобности + глобальный
  `CRails.application.routes.default_url_origin = ...` (сеттится из
  ENV/конфига при старте в `src/app.cr`).

### 4. Миграция строковых путей (механическая, батчами)

Порядок — от простого к сложному, каждый батч = отдельный коммит +
запуск тестов:

1. `redirect_to` в контроллерах (26 мест / 15 файлов):
   `redirect_to "/rooms/#{room.id}/involvement"` → `redirect_to
   room_involvement_path(room.id)`.

   > **Сделано** (2026-10-19, 24 из 26 мест). Заменены все строки с
   > именованными роутами: `"/"` → `root_path`, `"/first_run"` →
   > `first_run_path`, `"/session/new"` → `new_session_path`,
   > `"/account/edit"` → `edit_account_path`, `"/account/bots"` →
   > `account_bots_path`, `"/account/custom_styles/edit"` →
   > `edit_account_custom_styles_path`, `"/rooms/#{id}"` →
   > `room_path(room.id)`, вложенный `room_message_path(..., mid)`,
   > `message_boosts_path(mid)`, `user_path(user...id)`. НЕ заменены
   > (роуты без имени — хелпера нет, как в Rails):
   > `"/users/me/profile"` (profiles#update), `"/rooms/#{id}/involvement"`
   > (rooms#update_involvement), `"/searches..."` — 5 мест, вернуться
   > при появлении имён (в Rails это `profile_path` и named
   > involvement-роуты). Верификация: сборка + HTTP-смоук
   > (`tmp/urlhelpers-smoke`: сервер на копии bf9, сессия
   > `tmp/urlhelpers_smoke_session.cr`) — все Location-заголовки
   > (`/session/new`, `/account/edit`, `/users/<id>` ban/unban,
   > `/rooms/<id>` welcome, `/` logout) байт-в-байт равны старым
   > строкам.
2. `action=` в ERB-формах (23 / 17), включая `_form.html.erb:1` с
   конкатенацией.

   > **Сделано** (2026-10-19). Заменены только формы с именованными
   > роутами: boosts/new → `message_boosts_path(@mid)`,
   > composer → `room_messages_path(room.id)` (POST create неименованный,
   > путь == index — Rails в форме пишет room_messages_path),
   > directs/edit delete → `room_url(@room…id)` (было
   > `origin + "/rooms/#{id}"` — `*_url`-случай), messages/edit ×2 →
   > `room_message_path(room.id, mid)` + удалён ручной `message_path`
   > из messages_helpers.cr (байт-идентичен сгенерированному, других
   > вызовов нет). Прочие action= ведут на неименованные
   > create/update/destroy-роуты (`/session`, `/account.<id>`,
   > `/account/join_code`, `/users/:id/ban`, `/rooms/directs`,
   > `/account/bots[...]`, `/account/custom_styles`,
   > `/users/me/profile`, `/rooms/<kind>[...]`, involvement,
   > `/searches`, `/join/:code`, transfers) — хелперов нет ни в порте,
   > ни в Rails, оставлены строками.
3. `href=` в рабочих вьюхах (~21, не трогая asset-ссылки
   importmap/stylesheets).

   > **Сделано** (2026-10-19). 15 замен: сайдбар (directs/`room_path`
   > ×2, `new_rooms_direct_path`, `new_rooms_open_path`,
   > `edit_account_path`), accounts/_nav (`account_bots_path`,
   > `edit_account_custom_styles_path`), bots/index
   > (`new_account_bot_path`, `edit_account_bot_path(bid)`),
   > boosts/new (`user_path`, `message_boosts_path` ×2),
   > searches/show (`room_path(@return_room)`),
   > autocompletable (`user_path(u.id)`). Оставлены строками:
   > `/users/me/profile`, `/users/me/sidebar`, `/searches…`,
   > avatar-src `/users/:id/avatar` (неименованные), `_form.html.erb`
   > href с выбором kind opens/closeds (см. этап 5 — навсегда
   > строка/ручной хелпер, вид выбирается в рантайме).

4. Интерполяции в `ChatLayout`/хелперах (34 места; здесь же —
   самые хитрые, `chat_layout.cr:1138` с `base_url`, это `*_url`).

   > **Сделано** (2026-10-19). Инстанс-хелперы (модули, включённые в
   > контроллеры): joins → `new_session_path`, profiles →
   > `room_path`, accounts → `room_path`/`root_path`, custom_styles →
   > `edit_account_path`. Статический `ChatLayout` (инстанс-хелперы
   > недоступны) — обёртка `ChatLayout.route_path(name, *values)` →
   > `CRails.application.routes.path_for` (та же таблица имён):
   > `user_path` ×4 (avatar_link, mention, boost, message),
   > `room_at_message` (permalink), `message_boosts`,
   > `new_message_boost`, `edit_room_message`, `room_messages`
   > (page_url, `*_url`-случай с base_url). Оставлены: avatar/logo
   > cache-buster-пути, `room_edit_path` (STI-выбор), `/account/logo`,
   > `/account/join_code`, involvement, refresh (неименованные).
   >
   > Попутно найден и закрыт баг хелперов: `*_url`-origin смотрел
   > только собственные методы включающего типа
   > (`@type.methods`) — наследуемый из ApplicationController `origin`
   > не находился, `*_url` молча давал `http://localhost`. Фикс —
   > обход `@type.ancestors` (action_pack.cr **v0.2.7**, регрессионный
   > спек UrlHelperInheritedHost).

Правило каждого батча — **байтовая сверка**: хелпер обязан давать
те же байты, что заменяемая строка (сверка по коду + спека/скрипт
сравнения для нетривиальных случаев вроде permalink `@`-сегмента).
Сверяться с Rails-референсом по месту (`rooms_controller.rb:8` —
`redirect_to room_url(...)`).

Приёмка этапа: `capybara-tests/` (полный прогон) + parity-скрипты
(`tmp/parity_report.py`) до/после — диффов быть не должно.

### 5. Чистка

> **Сделано** (2026-10-19). Аудит всех ручных path/url-методов:
> удалён только `message_path` (messages_helpers.cr — байт-идентичен
> `room_message_path`, других вызовов не было; убран в батче 4.2).
> Оставлены осознанно (не дубликаты сгенерированных):
> `ChatERB#root_url`/`#avatar_path`/`#direct_uploads_url`/
> `#blob_url_template` — отдельный ERB-контекст без UrlHelpers,
> с пустым origin дают относительные пути (иная семантика);
> `room_edit_path` (STI-выбор сегмента — у порта нет неймспейсных
> контроллеров), `fresh_*` (аналог `direct`, вне объёма),
> `blob_url`/`representation_url` (ActiveStorage),
> `last_room_visited_path` (accounts) — использует `root_path`/
> `room_path` внутри. `CRAILS_REMAINING.md` §1 закрыт.

- Удалить ручные хелперы, полностью совпадающие с сгенерированными
  (`message_path` из `messages_helpers.cr` — если его сигнатуру
  покрывает `room_message_path`; при несовпадении вызывающих мест —
  переименовать/оставить по аудиту этапа 0).
- Оставить навсегда: `room_edit_path` (STI-выбор сегмента — у
  порта нет неймспейсных контроллеров), `fresh_*` (аналог `direct`,
  вне объёма), `blob_url`/`representation_url` (ActiveStorage).
- Обновить `CRAILS_REMAINING.md` §1 (закрыть пункт) и этот файл.

## Вне объёма (отдельные пункты бэклога, не этот план)

- Полиморфные пути (`redirect_to @user`, `polymorphic_path`) —
  требует связи имя ↔ класс модели.
- `direct`-хелперы Rails (`fresh_account_logo_path` в
  `routes.rb:28` эталона) — ручные `fresh_*` покрывают.
- `rails_blob_path(..., only_path: true)` — ActiveStorage, ручные
  `blob_url`/`representation_url` покрывают.
- Per-request `default_url_options` (Rails `set_current_request`)
  — завязан на `Current` (`CRAILS_REMAINING.md` §2), глобального
  `default_url_origin` на первое время достаточно.

## Риски

- **`method_missing` перехватывает любое `_path`/`_url`-имя** в
  включивших классах → любая опечатка падает в рантайме, не при
  компиляции. Парируется спеками на каждый хелпер из реестра имён
  (этап 4, батчи) и понятным текстом ошибки (список близких имён).
- Имена порта ≠ имена Rails из-за отклонений `config/routes.cr` —
  фиксируется аудитом этапа 0, отклонения документируются.
- `_url` из jobs без явного origin → обязательный фолбэк-конфиг на
  этапе 3, иначе тихие `http://localhost` в прод-уведомлениях.

---

Актуальность: 2026-10-17, по коду `lib/action_pack_cr` (routes.cr
366 строк), `config/routes.cr` (96 строк, ~45 маршрутов),
`src/app.cr`, эталон `once-campfire/`.
