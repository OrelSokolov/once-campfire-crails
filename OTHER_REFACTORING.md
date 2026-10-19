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

**Сделано** (2026-10-19).

- `Boost belongs_to :message, touch: true` — убраны manual
  `UPDATE messages SET updated_at` в `boosts_controller` (create,
  destroy) и `boosts/by_bots#bot_create` (after_save/after_destroy
  коллбэки шарда);
- `Message belongs_to :room, touch: true` — раньше порт ВООБЩЕ не трогал
  rooms.updated_at при создании сообщения (в референсе трогает);
  touch выполняется внутри WriteQueue (save! зовётся в очереди,
  коллбэк синхронен) — из-под очереди не уходит;
- `messages_controller#update`: manual UPDATE → `message.touch`;
- `message_creator#store_attachment`: manual UPDATE → `record.touch`.

Верификация: `tmp/verify_touch.cr` (boost save!/destroy трогают
message, message save! трогает room — TOUCH OK) + e2e-смоук
(`tmp/boost_broadcast_smoke.js`): реальный POST буста — строка в
boosts, messages.updated_at обновлён коллбэком, cable-фрейм
байт-в-байт.

Отклонение от Rails: коллбэк шарда делает `find?(oid).touch`
(доп. SELECT перед UPDATE; Rails использует загруженную ассоциацию).
Кандидат на патч шарда.

## 3. Ручные where-строки → `scope` (base.cr:277)

**Сделано** (2026-10-19, частично).

- `Room`: scopes `opens/closeds/directs/without_directs/ordered` —
  но НЕ equality по type как в референсе: STI-порт хранит два
  написания type (сид 'Rooms::Open', создание портом 'Open'),
  условие расширено до `IN` обеих форм;
- `User`: `active`, `active_bots` (active + role=2), `ordered`
  (LOWER(name)) — user.rb / user/bot.rb референса.

Замены: `joins_controller` (Room.opens), `accounts/bots_controller`
(Room.opens, User.active_bots + order, visible_for без Direct),
`autocompletable/users_controller` (User.active), `rooms_controller`
(User.active).

Ограничение шарда: scope — только class-level метод, чейнинг на
Relation (`User.active.ordered`) не работает — в таких местах order
остаётся явным. Кандидат на патч шарда. Message.ordered/Boost.ordered
не добавлялись: единственные места сортировки сообщений — DESC+limit
(index) и подзапросы, scope не ложится.

Верификация: `tmp/verify_scopes.cr` — множества записей scopes ==
manual where (SCOPES OK).

## 4. Отсутствие валидаций → `validates` (validations.cr:45)

**Проверено — переносить нечего** (2026-10-19). В референсе
`validates` есть только в непортированных моделях
(opengraph/metadata.rb, push/subscription.rb). Лимит 16 у
`boosts.content` — schema-level (`t.string "content", limit: 16`
в schema.rb), НЕ модельная валидация; ручные проверки в
контроллерах порта (empty → 422, >16 → 422 у ботов) реализуют
контракт express-порта и Rails-валидаций не соответствуют.
Добавлять `validates` сверх референса — расхождение 1:1.

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

**Проверено — неприменимо пока** (2026-10-19). Негативные условия
в порте живут внутри raw-SQL подзапросов (`sidebars_controller`,
`message_creator`, `room.visible_for` — `involvement != 'invisible'`
внутри IN-подзапроса) — relation-level `where.not` туда не
подставить. Отдельные NOT IN-условия закрыты scope
`Room.without_directs` (п.3). Возвращаться при порте
opengraph/push-моделей (там `where.not` у референса).

## Верификация

Как в `plans/completed/ERB_REFACTORING.md`: побайтовое сравнение ответов до/после +
сверка фрагментов/бродкастов с Rails-оракулом (`localhost:3000`) под
нормализацией (`tmp/boost_oracle_diff.py`); для п.1 — сравнить
сгенерированный turbo-stream XML до/после байт-в-байт.
