# ERB_REFACTORING — вынос inline-HTML из контроллеров в ERB-вьюхи

Статус: завершено (13 пунктов инвентаризации + 2 найденных при сверке:
sessions, searches — оба закрыты). Эталон подхода — коммит `a6d5508`
(boosts: `app/views/boosts/{index,new}.html.erb` + implicit render).

## Цель

Убрать паттерн `render(html: String.build do |io| io << %(...) ... end)` из
контроллеров: разметка живёт в `app/views/**.html.erb`, компилируется на
этапе сборки, контроллер готовит данные. Структура — как в Rails-референсе
(`once-campfire/app/views/...`). Готово: все 15 контроллеров вынесены,
inline `render(html: String.build ...)` в контроллерах больше нет
(turbo-stream-ответы create/update/destroy — не вьюхи, остались как
были; rooms#show/sidebars и пр. — на ChatERB/ChatLayout, не трогались).

## Механика (по образцу boosts)

1. **Шаблон экшена**: файл `app/views/<controller>/<action>.html.erb`
   подхватывается фреймворком автоматически (`action_pack_cr` `macro
   finished`: `compile_template "__av_tpl_<action>"` + `__default_render`,
   если экшен не вызвал render). Ивары контроллера доступны шаблону
   напрямую, экранируются в `<%= %>` (String → HTML-escape, SafeString →
   как есть, прочее → `to_s` без экранирования — nilable-строки всегда
   явно `.to_s`!).
2. **Общие формы new/edit** — партиал с locals через `compile_partials`
   (образец — `ChatERB`), либо два шаблона с общим приватным методом
   билдера SafeString. Структуру брать из референса (`_form.html.erb`).
3. **Сырой HTML из ChatLayout** (icon/asset/dom-билдеры) — приватные
   хелперы контроллера, возвращающие `ERB::SafeString` (иначе `<%= %>`
   заэкранирует SVG/разметку).
4. **Layout**: `app/views/layouts/application.html.erb` отсутствует —
   «страничные» экраны сами печатают `page_open`/`head`/`<!doctype>` —
   это остаётся в шаблоне или хелпере, как сейчас.
5. **Byte-parity**: шаблон обязан воспроизводить текущий вывод порта
   байт-в-байт (включая переводы строк!). Внимание к хвостовому `\n`:
   например `boosts/index.html.erb` намеренно БЕЗ завершающего перевода
   строки после `<%= boosts_dom %>` — файл трогать нельзя без сверки.
   (Обновлено: с ERB_FORMATTING byte-parity гарантируется dedent-режимом
   компилятора — исходники вьюх теперь с отступами, ведущие пробелы
   строк срезаются при компиляции, см. `ERB_FORMATTING.md`.)
6. **Гочча экшен-детекции**: приватный 0-аргументный метод контроллера
   попадает в набор «экшенов» диспетчера — у хелперов должен быть хотя бы
   один аргумент (или не-0-аргументная сигнатура).
7. **Гочча постфиксных модификаторов**: `<%= expr if cond %>` НЕ
   компилируется — процессор оборачивает выражение в скобки вызова
   (`__erb_esc( expr )`), а Crystal запрещает постфиксный `if`/`unless`
   как аргумент (Ruby разрешает — поэтому в Rails-шаблонах так пишут).
   Вместо этого: тернарник `<%= cond ? expr : "" %>` (перегрузки
   `__erb_esc` принимают и String, и SafeString — ветки разного типа
   допустимы) либо `<% if cond %>...<% end %>`-блок. В `<% %>` (без `=`)
   постфиксные модификаторы работают как обычно.
   НО: тернарник с HTML-строкой (`cond ? "<hr>" : ""`) — String →
   HTML-ЭСКАНИРУЕТСЯ. Условные HTML-куски — только литералом внутри
   `<% if %>`-блока или SafeString-хелпером.
8. **compile_partials с union-локалами**: тип локала в `locals:`
   пишется `Room?`, НЕ `(Room | Nil)` — скобочный union парсится как
   Expressions и падает на `.resolve`. Первый HTML-партиал приложения —
   `rooms/_form` (new/edit комнаты).

## Верификация каждого шага (обязательна)

1. Сборка «до» и «после»: `crystal build src/app.cr -o tmp/app-before
   -Dwithout_mt` (release не нужен).
2. Оба сервера на тестовой копии БД (`DATABASE_URL=sqlite3:.../tmp/X.sqlite3`
   — копия `db/development.sqlite3`; сессия — `tmp/verify_boost_session.cr`
   как образец).
3. `curl` всех задетых эндпоинтов до/после → `diff`/`cmp` побайтово
   (заголовки расходятся только на `X-Request-Id`/`X-Runtime`).
4. Оракул — Ruby-версия на `localhost:3000`: фрагменты с заголовком
   `Turbo-Frame: <frame-id>`, сравнение нормализацией
   (`tmp/boost_oracle_diff.py`; LOGIN: cookie `session_token` подписать
   секретом сервера — `tmp/sign_rails_cookie.cr`; CSRF-POST требует
   cookie-jar с `_campfire_session` и per-form токеном из формы).
   Допустимые остаточные расхождения (уже зафиксированы): CSRF-инпут в
   формах Rails (у порта header-only), `&gt;` vs `->` в data-action,
   width/height у иконок, dom_id (публичный id vs числовой).
5. Краевые пути: 404 (недоступная сущность), unauth-редирект, пустые
   списки — сравнить до/после.

## Инвентаризация и порядок

Порядок: от простых full-page форм к сложным экранам с партиалами.

| # | Контроллер | inline | Что выносится | Вьюхи референса | Статус |
|---|------------|--------|---------------|-----------------|--------|
| 0 | `boosts_controller` | — | index/new | `messages/boosts/{index,new}` | ✅ `a6d5508` |
| 1 | `profiles_controller` | ~147 | `page()`: профиль-форма | `users/profiles/show` | ✅ |
| 2 | `accounts_controller` | ~137 | `page()`: аккаунт-форма | `accounts/edit` | ✅ |
| 3 | `first_runs_controller` | ~31 | форма первичной настройки | `first_runs/show` | ✅ |
| 4 | `welcome_controller` | ~22 | root-страница | `welcome/show` | ✅ |
| 5 | `custom_styles_controller` | ~19 | | `accounts/custom_styles/edit` | ✅ |
| 6 | `session_transfers_controller` | ~8 | | — | ✅ |
| 7 | `users_controller` | ~44 | страница юзера | `users/show` | ✅ |
| 8 | `joins_controller` | ~42 | join по коду | — | ✅ |
| 9 | `directs_controller` | ~41 | new ping + autocomplete | `rooms/directs/new` | ✅ |
| 10 | `autocompletable_users_controller` | ~17 | цикл lexxy-prompt-item | `autocompletable/users/_prompt_item` | ✅ |
| 11 | `messages_controller` | ~55 | `show` (full-page обёртка), `edit` (форма) | `messages/{show,edit}` | ✅ |
| 12 | `bots_controller` | ~202 | `bot_form` + index/edit | `accounts/bots/_form`, `index`, `edit` | ✅ |
| 13 | `rooms_controller` | ~293 | `room_form` (opens/closeds new+edit), `direct_edit` | `rooms/{opens,closeds}/_form`, `rooms/directs/{new,edit}` | ✅ |
| 14 | `sessions_controller` | ~75 | `render_login`: страница логина (+flash-401) | `sessions/new` | ✅ |
| 15 | `searches_controller` | ~27 | `show`: страница поиска (под PageCache) | `searches/index` (порт: `show`) | ✅ |

Сверка при закрытии 14–15 вскрыла ошибки прежней инвентаризации:
`sessions` ошибочно числился в «уже на ERB» (был String.build-билдером),
`searches` отсутствовал в таблице. Оба закрыты.

Уже на ERB/ChatERB (не трогать): `boosts`, `rooms#show`, `sidebars`,
`involvements`, `active_storage`, `avatars`, `logos`, `qr_codes`, `pwa`.
`up` — inline-heredoc-порт эндпоинта `rails/health#show` (встроенный
engine-эндпоинт Rails, в референсе вьюхи нет) — inline by design.
`messages#index` — fragment-коллекция (в референсе `layout false`) под
PageCache — не страница, не трогался.

## Заметки по конкретным пунктам

- **1–2 (profiles/accounts)**: простейшие — один экшен, один шаблон,
  `ChatLayout.page_open` печатается в шаблоне через SafeString-хелпер.
  Хороший кандидат проверить механику full-page экранов (без turbo-frame).
  1 (profiles) сделан: full-page механика подтверждена — `show.html.erb`
  начинается `<%= page_open(@user.not_nil!) %><section ...` (page_open без
  `\n` в конце) и заканчивается `<%= page_close %>` БЕЗ завершающего
  перевода строки в файле. Верификация: тела 200/auth, 302/unauth и
  пустой список комнат побайтово совпали (transfer-URL маскировался —
  он содержит origin+expires и различается by design).
  2 (accounts) сделан поверх той же механики: `page_close` с футером
  версии (`ENV["APP_VERSION"]`), условные ветки admin/non-admin и
  per-user crown — тернарниками (постфиксный if в `<%= %>` не
  компилируется, см. гоччу 7). Верификация: admin/non-admin × оба
  роута (/account, /account/edit) побайтово; restrict=true в sqlite
  недостижим (ColumnTypeMismatch на jsonb-колонке settings — латентный
  баг порта, «до» и «после» падают одинаково).
  3 (first_runs) сделан: статичная форма без данных — экшен пустой
  (redirect-ветка при существующем аккаунте ставит performed и
  implicit render не запускается); `page_open` с `body_class: "signup"`
  и user=nil. Верификация: 302-ветка и 21924-байтная форма —
  побайтово идентичны (в форме нет time/origin-зависимых данных).
  4 (welcome) сделан: sidebar-layout страница (не page_open — head +
  body.sidebar + пустой nav + message-area + aside + app-logo);
  redirect-ветка оставляет экшен без render → implicit render.
  Файл show.html.erb НЕБЛАГОНАДЕЖЕН для trim: заканчивается
  `</body></html>` С хвостовым `\n` (последний чанк оригинала его
  содержит). Верификация: 302-redirect (David), 19908-байтная
  empty-страница (Lonely Lou), unauth — всё побайтово идентично.
  5–8 (custom_styles, session_transfers, users, joins) — по той же
  механике; users — матрица viewer{admin,plain} × subject{self, plain,
  deactivated, banned, bot on, bot off, 404}, все идентичны; joins —
  форма/404/302-redirect при залогиненном.
  9–10 (directs/autocompletable): directs/new — статичная форма;
  autocompletable — цикл `<lexxy-prompt-item>` c sgid. Нюанс среды:
  `ChatLayout.attachable_sgid` требует env SECRET_KEY_BASE (без dev-
  fallback) — верифицировать с SECRET_KEY_BASE=$(cat tmp/local_secret.txt),
  иначе обе версии честно падают 500. JSON-ветка (jbuilder) не тронута.
  11 (messages): только show (обёртка `<!doctype html>` вокруг
  message_dom) и edit (форма в turbo-frame, ветка attachment).
  index (page-cache) и create/update/destroy (turbo-stream) — не вьюхи,
  не трогались.
  12 (bots): new/edit — два полных шаблона с общей формой (дублирование
  ~25 строк выбрано вместо партиала), index — вложенный цикл
  бот×комната×2 curl-команды (данные: @bots + @bot_rooms[bid] с
  NamedTuple-командами; curl-строки содержат origin — маскировать).
  13 (rooms): room_form — ПАРТИАЛ `rooms/_form.html.erb` через
  compile_partials в контроллере (тонкие new.html.erb/edit.html.erb
  рендерят его с locals; см. гоччу 8), direct_edit — ветка в
  edit.html.erb. QUIRK оригинала, воспроизведён байт-в-байт (файл
  _form.html.erb трогать только со сверкой): (а) при ≤20 юзерах
  search-инпут остаётся НЕЗАКРЫТЫМ (`<input ... full-width" ` без `>`;
  if в оригинале висел только на последнем чанке); (б) room_type
  switch: при checked — `class="switch__input" checked">`, при
  unchecked — `class="switch__input"">` (двойная кавычка). Верификация:
  new×2, edit×4 (open/closed/чужая-комната/не-админ), direct×2, 404,
  unauth — 10/10 побайтово.
- **9 (directs) → 10 (autocompletable)**: связаны (autocomplete-виджет);
  у 10-го цикл по юзерам — единственное место, где в шаблоне нужен
  `each` с интерполяцией внутри атрибутов (sgid, name).
- **12 (bots)**: `_form.html.erb` переиспользуется new/edit — первый
  случай для `compile_partials` с locals вне ChatERB, либо общий
  приватный билдер SafeString.
- **13 (rooms)**: самый большой: два вида комнат (opens/closeds) ×
  (new, edit) + directs/edit. Делать последним, после отладки механики
  на 1–12.
- **11 (messages#show)**: полный HTML-документ вокруг `message_dom` —
  обёртка `<!doctype>` остаётся в шаблоне (как `sidebars#show`).
- **14 (sessions)**: `new` — implicit render, create-неудача рендерит тот
  же шаблон через `render(html: __render_view("new").to_s,
  status: :unauthorized)` — jbuilder-ного `render(template:)`
  для ERB нет, но сгенерированный `__render_view` публичен. Flash-блок и
  value-атрибут email — SafeString-хелперы (`flash_html`, `email_value`),
  `panel shake` — строковый `panel_modifier`. Гочча переносов строк: в
  String.build-билдерах `\n` живёт ВНУТРИ чанков (`</label>\n</div>\n`,
  `Go</span>\n</button>`, `</footer>\n</main>`, `height="216">\n</a>` —
  6 мест) — при переносе в шаблон их легко слипить в одну строку; ловится
  только побайтовой сверкой. Верификация: new 200, POST-401 ×2 (с email →
  value-атрибут, без), unauth — тела+заголовки побайтово.
- **15 (searches)**: page-cache ПОВЕРХ шаблона: `__render_view("show").to_s`
  скармливается `PageCache::Page.new` как раньше был String.build — ETag
  (SHA1 тела) до/после совпал, что и доказывает идентичность кэшируемых
  байтов. search_composer позже перенесён в шаблон через `content_for
  :footer` (как в референсе; `page_close` читает `content_for(:footer)`),
  search_nav/recent_searches остались String-билдерами (прецедент
  account_nav/user_nav). Файл — `show.html.erb` по
  экшену порта (в референсе `index.html.erb`; роут `get "/searches", to:
  "searches#show"`). Тривиальная гочча сравнения: тело содержит origin
  (пермалинки `/rooms/N/@M` с base_url) — «до»/«после» сравнивать только
  на одном порту. Верификация: пустой q, выдача q=coffee (132 КБ), фраза
  в кавычках (экранирование data-query → `&quot;`), no-match, unauth 302,
  304 по If-None-Match — всё побайтово. FTS-синтаксис-ошибки (`q=a<b`,
  апостроф) — честный 500 в обеих версиях, трейс в теле содержит номера
  строк контроллера — не сравнивать.

## Артефакты верификации (tmp/, не коммитить)

- `tmp/verify_profile_session.cr` — сессия для David в БД из
  `DATABASE_URL` + подписанная cookie session_token (образец для всех
  последующих пунктов; пользователь — `USER_ID` env, см.
  `tmp/verify_empty_session.cr` для пустых списков);
- `tmp/app-before`, `tmp/app-after` — бинари для побайтового сравнения.
