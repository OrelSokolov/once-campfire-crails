# CRAILS_REMAINING — чего не хватает в шардах CRails

Дополняет `OTHER_REFACTORING.md` (там — что в CRails уже есть, но
делается руками). Здесь — возможности Rails-референса, которых в
шардах НЕТ, и из-за которых проект вынужден писать руками. Это задачи
по самим шардам (railties_cr / action_pack_cr), не по приложению.

## 1. Named route helpers: `*_path` / `*_url`

> **Сделано** (2026-10-19) — см. `URL_HELPERS_GENERATOR.md`: все этапы
> (0–5) выполнены; имена порта == Rails (21 имя), миграция
> redirect_to/action=/href=/ChatLayout проведена, неименованные роуты
> осознанно оставлены строками. Опубликовано: action_pack.cr v0.2.6
> (UrlHelpers) + v0.2.7 (фикс inherited-origin), railties.cr v0.1.13
> (route_set wiring).

**Статус в CRails**: отсутствует. `CRails::Routes::RouteSet` хранит
имена маршрутов (`route.name`, объявляются через `as:` / `resources`),
но методов-хелперов не генерирует — в `lib/railties_cr/src` нет ни
одного `*_path` (проверка: только asset-path внутренности).

**Последствие в проекте**: пути хардкодятся по всему коду:
`"/messages/#{mid}/boosts"`, `"/rooms/#{room.id}/messages"`,
`href="/users/#{user.id}"` — в контроллерах, ChatLayout и вьюхах.
Референс пишет `message_boosts_path(@message)`, `room_path(room)`.

**Что нужно в railties_cr**: после `routes.draw` генерировать на
этапе компиляции по имени маршрута метод
`def <name>_path(*args : String | Int64) : String` (и `_url` —
`<origin> + _path`), подставляя позиционные аргументы в динамические
сегменты `:id` / `:message_id` по порядку (урл-кодирование значений).
Маршруты без имени — как в Rails — хелпера не получают.

**Затем в приложении**: механическая замена строк-путей на хелперы
(отдельный проход по `ERB_REFACTORING`/`OTHER_REFACTORING`-вьюхам и
контроллерам: `redirect_to`, `form action=`, `href=`, turbo-frame
`src=`). Сверка: хелпер обязан давать те же байты, что текущие строки
(напр. `message_boosts_path(mid)` == `"/messages/#{mid}/boosts"`).

## 2. `Current` attributes (`Current.user`)

> **Сделано** (2026-10-21) — порт `ActiveSupport::CurrentAttributes` в
> active_support.cr **v0.1.8**: `class Current < AS::CurrentAttributes`
> с типизированными атрибутами (`attribute user: User?` — Crystal
> требует типов; nilable обязательно, `reset` пишет nil),
> класс-уровневыми аксессорами и `reset`/`reset_all` (реестр подклассов
> compile-time через `macro inherited`, `reset_all` генерируется
> top-level `macro finished` — та же идиома, что `ActionController::
> REGISTRY`). Отклонения: без instance-API/`set{}`/before_reset-
> колбэков (референс не использует); хранилище — процесс-глобальные
> class vars, НЕ fiber-изолированные (как и прочие глобальные кэши
> порта; безопасно при одном диспетче за раз).
>
> railties.cr **v0.1.15**: `ActiveSupport::CurrentAttributes.reset_all`
> в начале диспетчеризации запроса (семантика Executor) — значения не
> протекают между запросами; интеграционная спека (set → read в двух
> диспетчах). README active_support.cr поправлен (строка врала про
> fiber-locals до реализации).
>
> В приложении: `app/models/current.cr` (session/user/request +
> `request_host`/`request_protocol`/`account`, как current.rb
> референса); `ApplicationController` — `before_action
> :set_current_request`, `current_session`/`current_user`/
> `start_new_session_for` заполняют Current, `sessions#destroy`
> сбрасывает (terminate_current_session). ChatLayout: сигнатуры
> `head`/`page_open`/`body_open`/`system_welcome`/`message_area`
> больше не принимают текущего юзера — внутри `Current.user`
> (19 мест вызова обновлено); `avatar_link` и прочие произвольные
> юзеры — параметром, как в референсе. Верификация: спеки шардов
> (active_support 325 green, railties 45 с 1 предсуществующим фейлом
> оракула get_with_params), смоук на seed-БД (аноним — без
> current-user-id; комната/аккаунт/профиль — meta+admin body class+
> composer data-user-id; сброс admin→аноним без утечек);
> `rake build:crails` REBUILD=1; twinshot review default.
> Не портировано: `belongs_to ..., default: -> { Current.user }`
> (active_record_cr не поддерживает proc-дефолты) — контроллеры
> задают creator/booster явно, на вывод не влияет; вернуться при
> порте соответствующих фич.
>
> Итоговая верификация: спеки active_support.cr 325 green;
> railties.cr 45 примеров (1 фейл — предсуществующий оракул
> get_with_params, воспроизводится и без правки); `rake build:crails`
> REBUILD=1 чистый; capybara crails-сьют 72/72 (0 failures/errors);
> twinshot review default — 127/129, оба диффа soft_check PNG
> (custom-boost.png, mobile.png 0.299% при пороге 0.2% — DOM того же
> теста байт-идентичен, рендер-шум; в истории базлайна 127/129 и
> 128/129 чередуются на этих же файлах).

**Статус в CRails**: отсутствует — в `railties_cr`/`action_pack_cr`
нет аналога `ActiveSupport::CurrentAttributes`.

**Последствие в проекте**: референс использует `Current.user` /
`Current.session` в моделях и хелперах; порт тащит `current_user` из
контроллера параметром (напр. `ChatLayout.*` принимают `user`
явно) — из-за этого сигнатуры дом-билдеров шире рейлсовых, а модели
не могут сами спросить текущего юзера.

**Что нужно**: `ActiveSupport::CurrentAttributes`-порт в
`active_support_cr` (per-request instance, сброс между запросами
middleware-ом или around-диспетчером) + `set_current_request`-хук в
`action_pack_cr` (before_action в ApplicationController порта).

**Затем в приложении**: `Current.user = current_user` в
`ApplicationController`, использование `Current.user` в ChatLayout /
моделях вместо параметров. Менять аккуратно: это рефактор сигнатур по
всему `ChatLayout` — делать последним, после пунктов выше.

---

Проверка «реализовано ли уже» обязательна перед стартом каждого
пункта: `rg "_path|url_for|Current" lib/*/src` — списки выше
актуальны на 2026-10-17.
