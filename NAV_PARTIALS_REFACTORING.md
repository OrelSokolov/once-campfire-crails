# NAV_PARTIALS_REFACTORING — nav-хелперы String.build → ERB-партиалы

Статус: не начат. Отдельная задача, вне ERB_REFACTORING (тот закрыт:
inline-HTML контроллеров больше нет; здесь — хелперы вьюх, оставшиеся
на `String.build`/`io <<`).

## Цель

Разметка nav-баров «страничных» экранов (account, user, search) живёт в
Crystal-хелперах через `String.build do |io| io << %(...)`. Перевести её
в `app/views/**/_nav.html.erb` с блочным `link_to` — разметка в шаблонах,
хелперы становятся тонкими обёртками `render partial:`.

ОТСТУПЛЕНИЕ от структурного паритета, зафиксировать сознательно: в
Rails-референсе (`once-campfire/app/views/...`) эти куски — инлайн
`content_for :nav` в самих шаблонах, партиалов `_nav` там НЕТ.
Компенсация — byte-parity вывода (обязателен, см. верификацию). Если
позже встанет требование структуры 1-к-1 — свернуть обратно.

## Почему реализуемо (механика уже в CRAILS, ничего не добавлять)

- Блочный `link_to`: `lib/action_view_cr/src/helpers/url_helper.cr:15`
  (`link_to(url, **opts, &)` через `capture`, оракул-кейс `url_link_block`).
- ERB-компилятор понимает `<%= expr do %> ... <% end %>`:
  `lib/erb_cr/src/template_processor.cr:39-49` (счётчик `pending_do`
  закрывает скобку вызова на парном `<% end %>`).
- `compile_partials` + `render partial:, locals:`:
  `lib/erb_cr/src/rendering.cr:117`; образец в приложении —
  `app/controllers/rooms_controller.cr:32` (`rooms/_form`).
- `capture`/буфер-свайп: `lib/erb_cr/src/rendering.cr:40` — вложенные
  рендеры не топчут буфер родителя.

## Инвентаризация и порядок (от простого к сложному)

| # | Сейчас | Куда | locals | Экраны |
|---|--------|------|--------|--------|
| 1 | `AccountsHelpers#account_nav` (`app/helpers/accounts_helpers.cr:24`) | `app/views/accounts/_nav.html.erb` | `user` | /account/edit (admin, plain) |
| 2 | `UsersHelpers#user_nav` (`app/helpers/users_helpers.cr:12`) | `app/views/users/_nav.html.erb` | `viewer`, `subject` | /users/:id (self, чужой) |
| 3 | `SearchesHelpers#search_nav` + `#recent_searches_html` (`app/helpers/searches_helpers.cr:30,45`) | `app/views/searches/_nav.html.erb` (+ `_recent_searches.html.erb`, вложенный) | `query`, `count`, `recents` | /searches (пустой/непустой query × пустые/непустые recents) |

## Механика каждого шага

1. Создать `_nav.html.erb` с разметкой из референса (структура тегов —
   оттуда: `once-campfire/app/views/accounts/edit.html.erb:3-21` и
   аналоги users/show, searches), ссылки — блочным `link_to`, иконки —
   `<%= icon("bot.svg") %>` (ViewHelpers, как в остальных вьюхах).
2. Зарегистрировать в контроллере (не в ChatERB — партиал локален
   экрану):
   ```crystal
   compile_partials({
     "accounts/nav" => {path: "app/views/accounts/_nav.html.erb",
                        locals: {"user" => User}},
   })
   ```
3. Хелпер-обёртка (`nav_html:` у `ChatLayout.page_open` ждёт String,
   партиал возвращает `ERB::SafeString`):
   ```crystal
   def account_nav(user : User) : String
     render(partial: "accounts/nav", locals: {"user" => user}).raw
   end
   ```
4. Для шага 3: `recent_searches_html` цикл по `recents` — либо вложенный
   партиал `_recent_searches` (render из `_nav`), либо цикл `<% %>` в
   самом `_nav` (как `users.each` в `rooms/_form`). Форма clear
   (button_to-подобная) остаётся литералом.

## Гоччи (сводка из ERB_REFACTORING, действуют и здесь)

- **`\n` после `<%= %>` НЕ срезается** (trim только после `<% %>`,
  `template_processor.cr:53-54`), а текущий вывод nav-хелперов
  переводов строк НЕ содержит вовсе. Партиалы писать компактными
  строками, как `rooms/_form.html.erb` (там текст между тегами —
  перенос строки попадает в вывод только там, где он был в оригинале).
- Постфиксный `if`/`unless` в `<%= %>` не компилируется — тернарник
  `<%= cond ? " checked" : "" %>` или `<% if %>`-блок (ERB_REFACTORING
  гочча 7).
- Условный HTML-литерал (String) в тернарнике эскейпится — только
  `<% if %>`-блок или SafeString-хелпер.
- `icon`/`copy_button` возвращают SafeString — `<%= %>` не эскейпает.
- Типы локалов в `compile_partials` — `Room?`, не `(Room | Nil)`
  (гочча 8; здесь nilable-типов нет, но помнить).
- Хелпер-обёртка с аргументами — экшен-детекция не заденет (гочча 6).

## Верификация каждого шага (обязательна, byte-parity)

1. Сборка «до»/«после»: `crystal build src/app.cr -o tmp/app-before
   -Dwithout_mt` (release не нужен).
2. Оба сервера на копии БД (`DATABASE_URL=sqlite3:.../tmp/X.sqlite3`;
   сессия — `tmp/verify_boost_session.cr` как образец; для searches
   env `SECRET_KEY_BASE` не нужен, для attachable_sgid-вьюх нужен).
3. `curl` задетых эндпоинтов до/после → `cmp` побайтово (заголовки
   расходятся только на `X-Request-Id`/`X-Runtime`):
   - шаг 1: /account/edit × {admin, plain};
   - шаг 2: /users/:id × {self, чужой};
   - шаг 3: /searches × {пустой query, непустой} × {recents пусто,
     recents есть} (recents печатаются в nav — покрыть обе ветки
     формы clear).
4. Краевые: unauth-редирект 302 на каждом роуте.
5. Порядок внутри шага: сначала партиал рядом со старым выводом
   (временный `<%=` обоих в шаблон-пробник не заводить — сверять
   серверами «до»/«после», как в ERB_REFACTORING).

## Что НЕ входит

- `ChatLayout` целиком (io <<-билдеры layout-примитивов — отдельная
  тема, если вообще; там byte-parity критичнее, а ERB-выигрыш меньше).
- `UsersHelpers#transfer_link`, `SearchesHelpers#messages_html` и пр. —
  не nav; заводить отдельные пункты только по отдельному решению.
- Изменения шардов/lib (механика уже есть — патчить ~/myshards нечего).
