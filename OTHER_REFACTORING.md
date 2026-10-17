# OTHER_REFACTORING — возможности CRails, реализованные в шардах,
# но используемые в приложении вручную

Дополняет `ERB_REFACTORING.md` (разметка → вьюхи). Сюда — только то,
что фреймворк УЖЕ умеет, а проект делает руками. Порядок — по
соотношению выигрыш/усилия.

## 1. Turbo-stream бродкасты строками → `broadcast_*_to` (turbo_cr)

`lib/turbo_cr/src/broadcasts.cr`: `broadcast_append_to /
broadcast_replace_to / broadcast_remove_to / broadcast_prepend_to /
broadcast_refresh_to(streamables, target:, targets:, content:, html:,
partial:, attributes:)` — включая `attributes` (maintain_scroll) и
подпись stream-имени через `stream_name_from` внутри.

Ручные места (9): `boosts_controller` ×3 (create append, bot_create
append, destroy remove), `messages_controller` ×4, `rooms_controller`,
`message_creator`. Сделано: `directs_controller` — `Membership` включает
`Turbo::Broadcastable`, create зовёт `membership.broadcast_prepend_to
[user, "rooms"], target: :direct_rooms, partial: "users/sidebars/rooms/
direct"` (local `membership` Broadcastable подставляет сам); партиал —
`app/views/users/sidebars/rooms/_direct.html.erb` (ChatERB,
`compile_partials`), рендер по имени — через `Turbo.partial_renderer`
(src/app.cr). Транспорт: broadcast turbo_cr идёт через `Turbo.cable`
— это `CampfireCable` (config/cable.cr), доставляющий локально + в
шину CableBus, так что замена эквивалентна `Campfire.broadcast`.

До:
```crystal
stream = %(<turbo-stream action="append" target="boosts_message_#{mid}" maintain_scroll="true"><template>) +
  ChatLayout.boost_dom(mid, entry) + %(</template></turbo-stream>\n)
Campfire.broadcast(Turbo::Streams::StreamName.stream_name_from([room, "messages"]), stream)
```
После:
```crystal
broadcast_append_to([room, "messages"], target: "boosts_message_#{mid}",
  html: ChatLayout.boost_dom(mid, entry),
  attributes: {"maintain_scroll" => "true"})
```

Проверить перед заменой: broadcast-хелпер кладёт в шину тот же транспорт
(`Campfire.broadcast` / CableBus) и тот же байт-формат тега
(`attributes` на `<turbo-stream>`, `<template>`-обёртка).

## 2. Raw-SQL touch → `belongs_to ..., touch: true`

`lib/active_record_cr/src/associations.cr:335` — опция `touch:`
поддержана (рефлексия на линии 464). Ручные места:

- `boosts_controller` ×2 (`UPDATE messages SET updated_at = ?` в create
  и bot_create), `boosts_controller#destroy` (touch после удаления);
- `messages_controller` (touch сообщения);
- `message_creator` (touch сообщения/комнаты).

Перенести на декларацию в модели (`Boost belongs_to :message, touch:
true`) и убрать `UPDATE ... updated_at` из контроллеров. Сверить, что
touch выполняется в той же очереди/транзакции WriteQueue (сейчас
UPDATE идёт вручную внутри `WriteQueue.perform` — автотouch не должен
уйти из-под очереди на запись).

## 3. Ручные where-строки → `scope` (base.cr:277)

`macro scope(name, &block)` реализован, в `app/models` не используется.

Референс (`once-campfire/app/models/room.rb`):
```ruby
scope :opens,           -> { where(type: "Rooms::Open") }
scope :closeds,         -> { where(type: "Rooms::Closed") }
scope :directs,         -> { where(type: "Rooms::Direct") }
scope :without_directs, -> { where.not(type: "Rooms::Direct") }
scope :ordered,         -> { order("LOWER(name)") }
```
В порте — `where("type = ?")` / `where(name: nil)` вручную по
контроллерам и `ChatLayout`. Добавить scopes в `Room` (и `Message`
`ordered`), заменить вызовы.

## 4. Отсутствие валидаций → `validates` (validations.cr:45)

`macro validates(*columns, presence:, length:, numericality:, ...)`
и `macro validate` реализованы, модели порта их не используют. Сверить
валидации референса (`once-campfire/app/models/*.rb`) и перенести:
`Boost` (длина content ≤ 16), `User` и др. Убедиться, что save! в
WriteQueue не меняет порядок ошибок валидации против текущего
поведения (сейчас ограничения проверяются вручную в контроллерах,
например length ≤ 16 в boosts#create/bot_create — после переноса
ручные проверки убрать).

## 5. Дубли view-хелперов в ChatLayout → helpers из action_view_cr /
   turbo_cr

Реализовано и не используется:

| Шард | Хелпер | Чем дублируется в приложении |
|---|---|---|
| action_view_cr | `image_tag` (`asset_tag_helper.cr:27`) | `ChatLayout.icon` (img + width/height) |
| action_view_cr | `link_to`, `button_to` (`url_helper.cr`) | сырые `<a>`/`<button_to>`-формы |
| action_view_cr | `form_with` (`form_helper.cr:31`) | формы руками (`room_form`, `bot_form`, …) |
| action_view_cr | `dom_id` (`record_identifier.cr:9`) | `ChatERB#dom_id`, строки `boost_#{id}`, `message_#{mid}` в ChatLayout |
| action_view_cr | `csrf_meta_tags` | вручную в ChatLayout.head |
| turbo_cr | `turbo_frame_tag` (`helpers.cr:37`) | `%(<turbo-frame id="...">)` строки |

Делать совместно с ERB_REFACTORING: новые ERB-шаблоны писать на
хелперах; `ChatLayout` остаётся только для дом-билдеров без
framework-аналога (`message_dom`, `boosts_dom`). Перед заменой
сверить байт-формат хелперов с текущим выводом (порядок атрибутов,
`&gt;`-экранирование) — байтовые расхождения недопустимы без сверки
с оракулом.

## 6. `where.not` (relation.cr:172)

Реализован, в приложении не используется ни разу; negative-условия —
SQL-строками (`"name IS NOT NULL"` и т.п.). Применять по ходу других
пунктов (см. scope `without_directs` в п.3).

## Верификация

Как в `ERB_REFACTORING.md`: побайтовое сравнение ответов до/после +
сверка фрагментов/бродкастов с Rails-оракулом (`localhost:3000`) под
нормализацией (`tmp/boost_oracle_diff.py`); для п.1 — сравнить
сгенерированный turbo-stream XML до/после байт-в-байт.
