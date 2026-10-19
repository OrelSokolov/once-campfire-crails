# CRAILS_REMAINING — чего не хватает в шардах CRails

Дополняет `OTHER_REFACTORING.md` (там — что в CRails уже есть, но
делается руками). Здесь — возможности Rails-референса, которых в
шардах НЕТ, и из-за которых проект вынужден писать руками. Это задачи
по самим шардам (railties_cr / action_pack_cr), не по приложению.

## 1. Named route helpers: `*_path` / `*_url`

> **Сделано частично** (2026-10-19) — см. `URL_HELPERS_GENERATOR.md`
> (этапы 0/1/2/3 и redirect_to-батч выполнены; остались миграция
> `action=`/`href=`/ChatLayout и чистка ручных хелперов).

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
