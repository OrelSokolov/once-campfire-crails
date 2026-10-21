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

> **Сделано** (2026-10-21; form_with-часть была закрыта ранее в
> `FORMS_SUPPORT.md` — все формы переведены на `form_with`/`button_to`;
> проход по turbo-frame ERB-шаблонам закрыт тем же днём — см. ниже).
>
> - **image_tag ↔ ChatLayout.icon** — сделано: action_view.cr **v0.1.14**
>   добавляет статик-форму `AssetTagHelper.image_tag(source, opts)`
>   (байт-идентичную инстанс-методу; для дом-билдеров вне вью-контекста,
>   как `TagHelper.tag_options`). `ChatLayout.icon` теперь делегирует в
>   неё (`aria: {hidden}`, `size:`, `class:`). Wire-формат сверен с
>   живым rails-оракулом (8.2.0.alpha, `rails runner` через view_context):
>   `<img aria-hidden="true" src="/assets/x.svg" width="20" height="20" />`
>   — порт теперь совпадает с референсом и на проводе (старая ручная
>   строка была без self-closing слэша); в артефактах порядок атрибутов
>   нормализуется (harness/normalize.rb).
> - **turbo_frame_tag ↔ сырые `<turbo-frame>`** — сделано для сайдбара:
>   turbo.cr **v0.1.5** — `turbo_frame_tag` принимает доп. атрибуты
>   (`target`, `class`, `data: {...}` — вставка до loading/id/src, как
>   порядок ключей в гемe) + статик-форма
>   `Turbo::FramesHelper.turbo_frame_tag` (для ChatLayout-контекста).
>   Переведены: `ChatLayout.chat_sidebar_frame` (аналог
>   users/sidebar_helper.rb#sidebar_turbo_frame_tag) и обе ветки
>   `users/sidebars_controller` (turbo-frame-ответ и полный layout).
>   `->` в data-action tag_options экранирует как `-&gt;` — после
>   HTML-парсинга идентично сырой строке (DOM-нормализация).
>   **Проход по ERB-шаблонам закрыт** (2026-10-21, turbo.cr **v0.1.6**
>   + erb.cr **v0.1.5** + action_view.cr **v0.1.15**): сверены ВСЕ сырые
>   `<turbo-frame>` порта с референсом — хелпер у референса используют
>   три шаблона, они переведены на инстанс-форму `turbo_frame_tag`:
>   `rooms/involvements/_bell` (data-controller/action/
>   turbo-frame-url-param, id — `dom_id("involvement")`),
>   `rooms/involvements/show` (те же атрибуты, однострочник),
>   `messages/boosts/new` (`new_boost_message_<mid>`); ChatERB получил
>   `include Turbo::FramesHelper`. Остальные сырые фреймы (bell-сосед
>   `direct_rooms_control` в сайдбаре, `rooms/directs/new`,
>   `rooms/show/_composer`, `messages/edit`, `accounts/edit`) — у
>   Rails-референса ТОЖЕ сырые, остаются как есть (1:1). Для блочной
>   формы из ERB инстанс-хелпер переведён на capture-семантику (как
>   `button_to`): erb.cr 0.1.5 — `capture` возвращает SafeString для
>   аппендов в буфер (html_safe-семантика Rails CaptureHelper),
>   plain-строку из блока пропускает как есть → turbo_frame_tag
>   экранирует её (оракул `helper_turbo_frame_tag_block`), захваченный
>   вывод идёт raw; tag_builder block-ветка сохраняет экранирование
>   plain-строк; action_view.cr 0.1.15 — compile-фикс cache-хелпера
>   под union-тип capture. Переносы сохранены байт-в-байт: Erubi
>   съедает `\n` после `<% end %>` — компенсировано пустыми строками
>   (как в ERB референса). Смоук old vs new бинарь: /rooms/:id,
>   /rooms/:id/involvement, /messages/:mid/boosts/new — IDENTICAL;
>   спеки: erb.cr 14, action_view.cr 242, turbo.cr 12 — зелёные;
>   `rake build:crails` REBUILD=1 чистый; twinshot review default —
>   128/129 (1 soft_check PNG custom-boost.png, как в базлайне).
> - **dom_id** — фикс шарда сделан (action_view.cr v0.1.14:
>   namespace-underscore `Rooms::Open` → `rooms_open`, как
>   `model_name.singular_route_key`; был баг `rooms/open`). Принятие в
>   приложении заблокировано STI-двойным написанием type ('Open' из
>   порта / 'Rooms::Open' из сида — active_record_cr не материализует
>   STI-классы): `Room#dom_id`/`ChatERB#dom_id` остаются
>   port-специфичной компенсацией. Вернуться при STI-материализации.
> - **csrf_meta_tags** — строка таблицы устарела: порт (как и оракул
>   rails-main с lazy-сессиями) НЕ эмитит csrf-meta (защита форм
>   header_only по Sec-Fetch-Site; CSRF_TOKEN в ChatLayout — только для
>   file_uploader fetch). Дублирования нет — переносить нечего.
>
> Верификация: спеки шардов (action_view.cr 242 green, turbo.cr
> frames_spec 5 green; turbo_stream_from починен под рекурсивный AttrVal
> union — компиляция сюита была сломана и до правок); смоук старый vs
> новый бинарь (6 страниц: сырой диф только self-closing слэш img и
> экранированный `->` в data-action — оба семантически идентичны после
> парсинга, подтверждено живым rails-оракулом 8.2.0.alpha); `rake
> build:crails` REBUILD=1 чистый; **twinshot review default — 128/129**
> (единственный диф — soft_check custom-boost.png; mobile.png, флaky на
> 0.2%-пороге в прошлых прогонах, здесь прошёл). Опубликовано:
> action_view.cr v0.1.14, turbo.cr v0.1.5; проект подтянул обе версии.

Реализовано и не используется:

| Шард | Хелпер | Чем дублируется в приложении |
|---|---|---|
| action_view_cr | `image_tag` (`asset_tag_helper.cr:27`) | ~~`ChatLayout.icon`~~ — сделано (v0.1.14, делегирует) |
| action_view_cr | `link_to`, `button_to` (`url_helper.cr`) | `button_to`-блоки переведены (FORMS_SUPPORT); сырые `<a>` в ChatLayout-дом-билдерах (`avatar_link` и т.п.) остаются: билдеры без 1:1, `href`-порядок link_to расходится с точностью шаблонов |
| action_view_cr | `form_with` (`form_helper.cr:31`) | ~~формы руками~~ — закрыто в FORMS_SUPPORT |
| action_view_cr | `dom_id` (`record_identifier.cr:9`) | фикс шарда сделан (v0.1.14); принятие в приложении заблокировано STI-двойным type (без материализации классов) — см. выше |
| action_view_cr | `csrf_meta_tags` | не дублируется: meta не эмитится (lazy-сессии, header_only) |
| turbo_cr | `turbo_frame_tag` (`helpers.cr:37`) | ~~`chat_sidebar_frame`/sidebars~~ — сделано (v0.1.5); ERB-шаблоны переведены (v0.1.6): bell, involvements/show, boosts/new — у остальных сырых фреймов референс тоже сырой |

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
