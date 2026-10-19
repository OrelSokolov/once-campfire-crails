# OTHER_REFACTORING — возможности CRails, реализованные в шардах,
# но используемые в приложении вручную

Дополняет `plans/completed/ERB_REFACTORING.md` (разметка → вьюхи). Сюда — только то,
что фреймворк УЖЕ умеет, а проект делает руками. Порядок — по
соотношению выигрыш/усилия.

## 1. Turbo-stream бродкасты строками → `broadcast_*_to` (turbo_cr)

**Сделано** (2026-10-19). `ApplicationController` включает
`Turbo::Streams::Broadcasts` (как turbo-rails engine.rb в
ActionController::Base); все 8 ручных `Campfire.broadcast` заменены:

- `boosts_controller` ×2 (create append + maintain_scroll, destroy
  remove target `boost_<id>`);
- `messages_controller` ×2 (destroy remove, update replace
  presentation + maintain_scroll);
- `messages/by_bots#bot_create` (append message);
- `messages/boosts/by_bots#bot_create` (append boost);
- `message_creator.broadcast` (append message,
  `Turbo::StreamsChannel.broadcast_append_to` — статический контекст);
- `rooms_controller#broadcast_sidebar_link` (prepend shared_rooms).

Нюансы реализации:

- `attributes` (maintain_scroll) в turbo_cr пробрасывает только
  `broadcast_action_to` — вызовы с атрибутами идут через него
  (`broadcast_action_to(streamables, :append/:replace, ...)`).
  Кандидат на патч шарда: прокинуть `attributes` в
  `broadcast_append_to`/`broadcast_replace_to`, как в turbo-rails.
- Байтовая сверка с оракулом (gem turbo-rails 30cd8fcc,
  `turbo_stream_action_tag` + ActionView::TagHelper; фиксация вывода —
  `tmp/verify_broadcast_tags.cr`): новые теги == оракул байт-в-байт.
  При этом СТАРЫЕ ручные строки расходились с оракулом по двум пунктам
  — замена их починила:
  1. порядок атрибутов: гем ставит `**attributes` (maintain_scroll)
     ПЕРЕД action/target, ручные строки — после;
  2. хвостовой `\n` после `</turbo-stream>`: в референсе он есть
     только в HTTP-ответах turbo_stream-шаблонов (перевод строки в
     конце ERB-файла: create/destroy.turbo_stream.erb), cable-фреймы
     его не содержат. HTTP-тела (messages create/destroy,
     by_bots bot_create) оставлены вручную байт-в-байт — это аналоги
     turbo_stream-шаблонов, не cable-фреймы.
- В `boosts/by_bots#bot_create` добавлен потерянный `\n` партиала
  `_boost.html.erb` в template (как в boosts_controller#create).
- Рантайм-смоук: сервер на копии bf9-БД, подписка на
  Turbo::StreamsChannel комнаты, POST буста — захваченный ws-фрейм
  `<turbo-stream maintain_scroll="true" action="append"
  target="boosts_message_<id>"><template>…boost_dom\n…
  </template></turbo-stream>` — SMOKE OK (tmp/boost_broadcast_smoke.js).

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

Как в `plans/completed/ERB_REFACTORING.md`: побайтовое сравнение ответов до/после +
сверка фрагментов/бродкастов с Rails-оракулом (`localhost:3000`) под
нормализацией (`tmp/boost_oracle_diff.py`); для п.1 — сравнить
сгенерированный turbo-stream XML до/после байт-в-байт.
