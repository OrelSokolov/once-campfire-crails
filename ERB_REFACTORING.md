# ERB_REFACTORING — вынос inline-HTML из контроллеров в ERB-вьюхи

Статус: в процессе. Эталон подхода — коммит `a6d5508`
(boosts: `app/views/boosts/{index,new}.html.erb` + implicit render).

## Цель

Убрать паттерн `render(html: String.build do |io| io << %(...) ... end)` из
контроллеров: разметка живёт в `app/views/**.html.erb`, компилируется на
этапе сборки, контроллер готовит данные. Структура — как в Rails-референсе
(`once-campfire/app/views/...`). Осталось ~1100 inline-строк в 13
контроллерах.

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
6. **Гочча экшен-детекции**: приватный 0-аргументный метод контроллера
   попадает в набор «экшенов» диспетчера — у хелперов должен быть хотя бы
   один аргумент (или не-0-аргументная сигнатура).

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
| 1 | `profiles_controller` | ~147 | `page()`: профиль-форма | `users/profiles/show` | ⬜ |
| 2 | `accounts_controller` | ~137 | `page()`: аккаунт-форма | `accounts/edit` | ⬜ |
| 3 | `first_runs_controller` | ~31 | форма первичной настройки | `first_runs/show` | ⬜ |
| 4 | `welcome_controller` | ~22 | root-страница | `welcome/show` | ⬜ |
| 5 | `custom_styles_controller` | ~19 | | `accounts/custom_styles/edit` | ⬜ |
| 6 | `session_transfers_controller` | ~8 | | — | ⬜ |
| 7 | `users_controller` | ~44 | страница юзера | `users/show` | ⬜ |
| 8 | `joins_controller` | ~42 | join по коду | — | ⬜ |
| 9 | `directs_controller` | ~41 | new ping + autocomplete | `rooms/directs/new` | ⬜ |
| 10 | `autocompletable_users_controller` | ~17 | цикл lexxy-prompt-item | `autocompletable/users/_prompt_item` | ⬜ |
| 11 | `messages_controller` | ~55 | `show` (full-page обёртка), `edit` (форма) | `messages/{show,edit}` | ⬜ |
| 12 | `bots_controller` | ~202 | `bot_form` + index/edit | `accounts/bots/_form`, `index`, `edit` | ⬜ |
| 13 | `rooms_controller` | ~293 | `room_form` (opens/closeds new+edit), `direct_edit` | `rooms/{opens,closeds}/_form`, `rooms/directs/{new,edit}` | ⬜ |

Уже на ERB/ChatERB (не трогать): `boosts`, `rooms#show`, `sidebars`,
`involvements`, `sessions`, `searches`, `active_storage`, `avatars`,
`logos`, `qr_codes`, `pwa`, `up`.

## Заметки по конкретным пунктам

- **1–2 (profiles/accounts)**: простейшие — один экшен, один шаблон,
  `ChatLayout.page_open` печатается в шаблоне через SafeString-хелпер.
  Хороший кандидат проверить механику full-page экранов (без turbo-frame).
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

## Артефакты верификации (tmp/, не коммитить)

- `tmp/boost_oracle_diff.py` — нормализатор + дифф фрагментов;
- `tmp/sign_rails_cookie.cr` — подпись session_token секретом оракула;
- `tmp/verify_boost_session.cr` — образец создания сессии в тестовой БД;
- `tmp/app-before`, `tmp/app-after` — бинари для побайтового сравнения.
