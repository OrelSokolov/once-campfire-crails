# capybara-tests — browser parity: Rails vs crails

Ruby-замена удалённой JS-версии browser-parity. Каждая страница открывается в
headless Chrome (cuprite/ferrum), для каждого состояния снимаются два артефакта —
полностраничный PNG и нормализованный HTML, — которые затем побайтово/попиксельно
сравниваются между таргетами.

- **rails** — upstream once-campfire (бенчмарк-копия в `../bench-workspace/once-campfire`).
- **crails** — форк в корне репо (`..`).

## Запуск

```bash
TARGET=rails bin/run           # полный прогон, артефакты → artifacts/rails/
TARGET=crails bin/run          # артефакты → artifacts/crails/
bundle exec ruby harness/compare.rb rails crails   # отчёт → artifacts/compare/
```

`bin/run` сам поднимает таргет (свежая копия сида, случайный порт, свой
redis/jobs-db для rails), прогоняет сьют и гасит его. Аргументы после
`--target` пробрасываются в minitest:

```bash
TARGET=rails bin/run -n /RoomsTest/          # фильтр по имени теста
TARGET=rails bin/run -n /test_renders_room/  # фильтр по одному тесту
```

Переменные окружения:

| Переменная        | Значение по умолчанию        | Что делает                                                                 |
|-------------------|------------------------------|----------------------------------------------------------------------------|
| `TARGET`          | `rails`                      | Какой таргет поднимать.                                                    |
| `PARITY_ARTIFACTS`| `artifacts/<target>`         | Куда писать артефакты (для второго базлайн-прогона).                      |
| `PARITY_SEED`     | `20260302`                   | Seed minitest: фиксированный порядок тестов ⇒ одинаковая контаминация.     |
| `PARITY_KEEP`     | –                            | `=1` — не удалять сид-каталог таргета (`tmp/seed-crails-*`) после прогона. |
| `MAX_DIFF_RATIO`  | `0.002`                      | Доля попиксельной разницы PNG, выше которой артефакт считается FAIL.       |

Руби — системный asdf-инсталлятор напрямую (`~/.asdf/installs/ruby/4.0.7/bin/ruby`);
asdf-шимы не используются. `bin/run` сам чистит `GEM_HOME`/`GEM_PATH` и пр.

Сид: `../bench-workspace/once-campfire-verification/fixtures/default/` —
копируется в свежий каталог на каждый прогон (БД + файлы), внешние endpoint'ы
(push/webhook) карантируются на `127.0.0.1:9`.

## Сьют

`tests/01..11_*_test.rb` — minitest + capybara. Порядок фиксирован seed'ом.
72 теста, ~130 артефактов на таргет (PNG+HTML по каждому `snap`).

## Harness

| Файл                  | Роль                                                                                                     |
|-----------------------|----------------------------------------------------------------------------------------------------------|
| `harness/boot.rb`     | Подъём/гашение таргета, копия сида, карантин endpoint'ов, чистое окружение для дочерних процессов.        |
| `harness/states.rb`   | Кэш сессий по ролям: логин один раз, куки ре-валидируются через `GET /users/me/sidebar` (401 ⇒ ре-логин).  |
| `harness/snap.rb`     | `settled_snap`: ожидание «network idle + turbo-frame complete + нет анимаций + двойной rAF», затем PNG и HTML. |
| `harness/normalize.rb`| Нормализация HTML перед сравнением (см. ниже).                                                            |
| `harness/compare.rb`  | Сравнение артефактов, `artifacts/compare/report.html` + `summary.json`.                                    |
| `harness/report.rb`   | HTML-рендер отчёта.                                                                                       |
| `bin/parity`          | Быстрый запуск одного теста с `PARITY_KEEP=1`.                                                            |

## Детерминизм

Два подряд rails-прогона дают побайтово одинаковые артефакты (0 diff).
Что для этого сделано:

- **Фиксированный seed** — одинаковый порядок тестов и, значит, одинаковая
  межтестовая контаминация БД.
- **`stable_html`** — двойной захват нормализованного HTML до совпадения
  (до 6 попыток): гасит гонки турбо-фреймов и late-обновлений DOM.
- **`settled`** перед скриншотом: все `turbo-frame[src]` complete,
  `getAnimations() == 0`, двойной `requestAnimationFrame`, `document.fonts.ready`,
  все `<img>` загружены.
- **Инжект `quiet`-CSS** (`animation: none`, прозрачный caret) и удаление
  `.flash` перед снимком.
- **Стаб View Transitions**: ferrum-расширение `tmp/no-view-transitions.js`
  подменяет `Document.prototype.startViewTransition` (флагами Chrome отключить
  нельзя; extensions в ferrum — это пути к файлам).
- **`mask_times`**: `time`-элементы скрываются только для PNG (в HTML время
  нормализуется, не выбрасывается).
- **Нормализация HTML** (`harness/normalize.rb`): CSRF-токены, base URL →
  `__BASE__`, порт → `__PORT__`, `?v=` → `__V__`, время/epoch → `__TIME__` /
  `__EPOCH__`, клиентские id → `__CID__`, signed-stream-name, QR base64,
  transfer-токены → `__TOKEN__`, `tabindex="-1"`, turbo busy/complete,
  cable-source connected, whitespace-скраб и сортировка атрибутов вне `<pre>`.

## Сравнение

`harness/compare.rb rails crails`:

- **PNG**: сначала равенство байтов (тот же рендерер ⇒ при нуле diff должен
  совпадать побайтово), иначе попиксельный подсчёт доли разных пикселей
  (chunky_png) против `MAX_DIFF_RATIO` (0.002 = 0.2%).
- **HTML**: `diff -u` по нормализованным файлам.
- Отчёт: `artifacts/compare/report.html`, машинный итог — `summary.json`.
  Артефакт, отсутствующий у таргета (тест упал до `snap`), помечается
  `missing` — это тоже парити-сигнал.

## Известное: сегфолт crails

`bin/app` (crails) падает по segfault (signal 11) где-то в течение
многосессионных live-тестов; поодиночке те же тесты проходят, краш
кумулятивный. Harness это переживает: `before_setup` каждого теста
проверяет сервер (`GET /up`) и при смерти перезапускает его на том же
data-каталоге (БД и файлы сохраняются, куки/сессии валидны). Тест, во время
которого сервер умер, падает и не пишет артефакты (→ `missing` в отчёте) —
это и есть сигнал краша; остальные тесты прогоняются дальше.

Тесты, падающие на crails до снимка, не пишут артефакты — список таких
«дыр» виден в отчёте как `missing in target`. **Фикс расхождений crails —
отдельная задача**, сьют и harness целенаправленно не «прощают» различия:
сначала артефакт, потом разбор.
