# ONCE Campfire на CRails — план работ

Участие в бенчмарке [basecamp/once-campfire-verification](https://github.com/basecamp/once-campfire-verification):
реализация Campfire на CRails (Crystal), проходящая общие гейты корректности,
с замером RPS по методологии 37signals (4 аппаратных ядра на приложение,
16 параллельных клиентов, 3 раунда).

## Репозитории

| Что | Где | Статус |
|---|---|---|
| Harness (форк, сюда пушим патч `crails`) | https://github.com/OrelSokolov/once-campfire-verification | ✅ форк сделан |
| Реализация (этот репозиторий) | `~/once-campfire-crails` → github.com/OrelSokolov/once-campfire-crails | папка создана |
| Rails-оракул (сабмодуль express-репо, рев. 659f957) | `~/rails.cr/tmp/campfire-express/reference` | склонирован |
| Express-реализация — путеводитель по подсистемам | `~/rails.cr/tmp/campfire-express` | склонирован |
| Клон verification для чтения | `~/rails.cr/tmp/campfire-verification` | склонирован |
| Фреймворк CRails (монорепо, шарды публичны) | `~/rails.cr` | шарды на GitHub публичны |
| Транспорт: nginx-модельный HTTP-сервер | `~/serverX.cr` → publish на GitHub | совместим с `HTTP::Handler` + upgrade (WebSocket) |

### Транспорт — ServerX (решение)

HTTP-транспорт приложения — [`~/serverX.cr`](https://github.com/…) (nginx-модель:
буфер на соединение, offset-парсер без per-request аллокаций, master/worker
`SO_REUSEPORT`). Совместимость проверена по коду: поднимает любой stock
`HTTP::Handler`; upgrade-механизм stdlib (`response.upgrade_handler`,
`serverx/app_server.cr:144`) — тот же, что использует Action Cable
(`action_cable.cr/src/server.cr:103`). Роутер приложения + `ws_handler` кабеля
складываются в одну цепочку хендлеров.

- Подключаем **с Фазы 1** (не как перф-оптимизацию позже): смена транспорта
  после валидации контрактов = повторная валидация всего.
- `WEB_CONCURRENCY=3` из harness → `--workers 3`; многопроцессность + SQLite
  через WAL/busy_timeout — схема, уже обкатанная express (cluster + reusePort).
- Выигрыш по RESULTS.md serverX: +15–50% RPS на транспорте, GC-churn ниже
  в 70–370 раз, лучший p99; один прогон с stdlib `HTTP::Server` оставим
  как baseline для нашего README.
- Перед публикацией: запушить serverX.cr на GitHub (сейчас в shard.yml
  плейсхолдер `your-fork/serverX.cr`) — зависимость должна быть публичной.
- В topology compare.rs честно описать: `crystals: {processes: N (SO_REUSEPORT),
  transport: "serverX (nginx-style)", cable: "ActionCable upgrade", jobs: ...}`.


Важно: harness ищет исходники реализации как **sibling-папку** рядом с собой:
`File.join(workspace, "once-campfire-#{kind}")` → чекауты должны лежать рядом:
`~/once-campfire-verification` + `~/once-campfire-crails`.

## Как harness принимает реализацию (уже разведано)

`bench/compare.rb`:
- строка 32: `allowed = %w[rails django laravel express express-bun elixir go rust c cpp]`
  → добавить `crails`;
- строка 93: образ по умолчанию `once-campfire-#{app}:app` → `once-campfire-crails:app`
  подставится **автоматически**,override через `CRAILS_IMAGE`;
- строки 120–130: case-блок топологии → добавить `when "crails"`;
- docker-run монтирует сид в `/rails/storage/{db,files,logs}` и передаёт env:
  `WEB_CONCURRENCY=3, JOB_CONCURRENCY=3, HTTP_PORT, TARGET_PORT, RAILS_LOG_LEVEL=warn`.

Порядок прогона одного раунда (compare.rb:88–160+):
1. `prepare_storage` — копия сида в tmp;
2. `docker run -d --network host --cpuset-cpus 8-11` — наш образ;
3. readiness: ждёт готовности (нужен работающий `/up`);
4. `loadgen login --email ... --password ...` — **логин через форму** → cookie;
5. `loadgen scrape` — со страницы комнаты берёт CSRF-токен (может быть пустым) и путь CSS;
6. `BenchmarkContracts.prepare` — сборка контрактов с нашего же сервера;
7. `loadgen http` — нагрузка, каждый ответ валидируется контрактом;
8. `validate_acks` — аудит каждого подтверждённого POST по базе сида.

## Контракты ответов (bench/contracts.rb — источник истины)

| Роут | Проверка |
|---|---|
| `GET /rooms/:id` | 200; полная HTML-страница; `data-message-id="..."` ровно те ID, что в сид-SQL (40 последних, ASC); DOM-идентичности `id="message_<id>"` **или** `id="<client_message_id>"` для каждого; тела сообщений — состав слов из FTS5-индекса |
| `GET /rooms/:id/messages?before=:anchor` | то же, но 40 сообщений до якоря |
| `GET /users/me/sidebar` | 200; полная страница; `shared_rooms`; все видимые имена комнат из сида (HTML-escaped) |
| `GET /searches?q=coffee` | 200; полная страница; ID = FTS5 `MATCH 'coffee'` с join по membership/email из сида, 100 шт, ASC |
| `GET /users/:token/avatar` | 200; `image/*`; байты валидны ffprobe (кадр, размеры > 0); байт-точность против собственных preflight-байтов |
| `GET <css>` | 200; `text/css`; содержит `{`; байт-точность |
| `GET /up` | 200; `background-color: green` |
| `POST /rooms/:id/messages` | 200; `text/vnd.turbo-stream.html`; `action="append"`; `target` = единственный `id="messages_room_<id>"`; после записи: точный persisted ID, тело, комната, запись в `message_search_index` |

Контракты снимаются **с нашего сервера** на preflight (не с Rails), поэтому
байт-паритета с Rails не требуется — требуется семантическая корректность
(ID из базы, валидные картинки, валидный HTML).

## Фазы

### Фаза 0 — SQLite-адаптер в `active_record.cr` (фреймворк)
- Обёртка `crystal-sqlite3` поверх существующего `DB::Database` API
  (`connection.cr` сейчас только PG; URL-builder → `sqlite3:` scheme).
- FTS5: виртуальная таблица `message_search_index` — raw SQL работает из коробки,
  нужен проход по type-маппингу результатов.
- Rails 8 pragmas при открытии: WAL, `synchronous=NORMAL`,
  `journal_size_limit=64MB`, `cache_size=2000`, `mmap_size=0`.
- Оракул-спеки против `sqlite3` CLI (AGENTS.md: сначала тест-кейсы).
- **Done:** спеки зелёные; `SELECT ... FROM message_search_index ... MATCH` через AR работает.

### Фаза 1 — HTTP-приложение под контракты (приложение)
Каркас `crails new` в `~/once-campfire-crails`, зависит от публичных шардов.
Транспорт — ServerX (см. выше), воркеров настраиваем через `WEB_CONCURRENCY`.
- Схема: не миграции — читаем готовый сид (`db/production.sqlite3`),
  модели: User, Account, Room (+ Rooms::Open/Direct), Membership, Message,
  Session, Ban, Boost.
- Логин-форма → своя подписанная session-cookie (Rails-формат AES-256-GCM
  — совместимость с чужими сессиями для бенчмарка не нужна, логин свежий;
  но формат сделаем совместимым, как у express — пригодится для browser-gate
  «session transfer»).
- Роуты таблицы выше + bcrypt-проверка пароля (порт в devise.cr уже есть).
- POST message: вставка + FTS5-индекс + persist джоб-записей до ответа
  (уведомления/push/webhooks — как express: батч в отдельную leased-SQLite очередь).
- Шаблоны: конвертация ERB → ECR из `reference/app/views` (механическая;
  express прошёл этот путь байт-в-байт через nunjucks→eta — у нас путь короче).
- Статика: `/up`, CSS, avatar-байты из storage сида.
- **Done:** `bin/benchmark --apps crails --preflight` в форке проходит
  контракты без единого invalid; первые RPS-числа.

### Фаза 2 — Action Cable + браузерный гейт
- Живые сообщения через ActionCable-порт (Iteration 4 ✅): стримы комнаты,
  presence, отмена прав отзывает подписку.
- `bin/browser --base ...` (Playwright): установка, live-сообщения,
  редактирование, поиск, права, приглашения, session transfer.
- **Done:** браузерный гейт зелёный на свежем инстансе.

### Фаза 3 — производительность
- Fragment cache по ключу `template digest + id + updated_at + presentation-v3`.
- ETag/304 на messages page (аналог `fresh_when`).
- gzip крупных HTML; прекомпрессия ассетов (.br/.gz).
- Whole-page response cache per-worker с инвалидацией по DB-поколению.
- Тюнинг: WEB_CONCURRENCY=3 (воркеры с reusePort, как у express) или
  1 процесс на fiber'ах — замерить оба.
- **Done:** стабильные числа в 3 раундах, сравнимо с Go..Rust.

### Фаза 4 — публикация
- Опубликовать `serverX.cr` на GitHub (публичная зависимость приложения);
- Dockerfile (образ `once-campfire-crails:app`, пути `/rails/storage/*`);
- патч форка harness (`allowed` + топология), push на
  github.com/OrelSokolov/once-campfire-verification;
- README с методологией и таблицей результатов (как у express-репо);
- опционально PR в basecamp — включат официальную колонку или нет, решают они.

## Ориентиры и ожидания

Таблица-цель (RPS, 16 клиентов / 4 ядра): Rails ~4.1–4.3k, Go ~53–60k,
Rust ~100–120k. CRails с hello 142k RPS на спокойных страницах должен
приземлиться в диапазон Go..Rust при KLOC ~6–8 (уровень Express, не Rust 30.7).

## Риски

- **SQLite-адаптер** — главный технический риск (блокер Фазы 1); FTS5 в
  системной библиотеке есть, проверено.
- **Avatar ffprobe-валидация** — ActiveStorage-варианты у нас P0 (Disk);
  для сида достаточно отдавать готовые файлы из storage.
- **Browser-gate** самый долгий кусок ручной возни; сознательно после Фазы 1 —
  числа в headline-таблице он не требует.
- Сид строится публичным Rails-приложением (fixtures builder, рев. 90b3300) —
  от нас не зависит, `bin/seed` в форке.

## Текущий шаг

**Фаза 0 — ✅ закрыта (2026-10-13):** SQLite-адаптер в `active_record.cr`
(`crystal-sqlite3` 0.23.0; Rails 8 pragmas; FTS5; интроспекция `PRAGMA
table_info` → schema.yml; оракул-спеки против sqlite3 CLI 17/17; PG-сьют
283/283 не тронут; отдельным прогоном в `rake spec`).

**Фаза 1 — роуты закрыты, ручная верификация 8/8 (2026-10-14):**
- каркас `~/once-campfire-crails` собирается, `/up` отвечает (green contract);
- канонический сид построен через `ruby bin/seed` форка
  (`~/once-campfire-verification/fixtures/default`: sqlite + storage +
  labels.json + reference.env; 10 users / 11 rooms / 169 messages);
- dev-база = копия сида (`VACUUM INTO`), schema.yml сдамплен с реального
  сида — таблицы совпадают 1:1, FTS5-тени исключаются;
- модели объявлены (User, Room, Membership, Message, Session, Account, Ban,
  Boost, Search, Webhook, PushSubscription, ActionTextRichText,
  ActiveStorage*); ассоциации belongs_to/has_many;
- smoke на реальном сиде зелёный (`script/model_smoke.cr`): david, видимые
  комнаты, тела сообщений через ActionText, FTS5 MATCH паритет с CLI (13=13),
  avatar jason (blob key/ct/bytes), session.

Контрактные роуты — все сверены вручную curl-ом против dev-копии сида:
- `POST /session` → signed permanent cookie; `GET /rooms/:id` 40 сообщений ASC,
  data-message-id = сид-SQL; `GET /rooms/:id/messages?before=` 40/40;
  `GET /users/me/sidebar`; `GET /searches?q=coffee` 13/13 (FTS5 паритет);
  `POST /rooms/:id/messages` turbo-stream append, аудит SQL 1|1|1;
  `/assets/application.css` 200;
- `GET /users/:token/avatar` — 200 `image/jpeg` (валидный JPEG 640×640,
  ffprobe nb_read_frames=1), мусорный токен → 404. Ключ подписи:
  PBKDF2-**SHA256**(SECRET_KEY_BASE, `"active_record/signed_id"`, 1000, 64)
  + HMAC-SHA256 (см. campfire-express rails.js `key()`/`verifyId`), purpose
  `user/avatar` (Rails комбинирует `"<model>/<purpose>"`). Отдача —
  `send_file` (inline, content_type из blob); Rails-референс шлёт webp-вариант,
  но контракт требует только `image/*` + ffprobe-валидность — оригинал проходит.
  ⚠ `render(plain:)` в action_pack сбрасывает статус — статус передавать
  аргументом `status:`.

Осталось до Done-критерия Фазы 1: формальный preflight через
`bin/benchmark --apps crails` (нужен патч compare.rb — allowed/топология/
Dockerfile; сами проверки contracts.rb уже воспроизведены вручную выше).

### Известные особенности (по ходу Фазы 1)

- **Инфлектор**: `searches → Searche` (нет правила `-es`): в ассоциациях
  указывать `class_name: "Search"` явно; правило добавить в active_support.cr.
- **Under-binding hazard (sqlite3/crystal-db)**: если в закэшированный
  prepared statement передать меньше аргументов, чем `$N`-плейсхолдеров в
  SQL, несвязанные параметры сохраняют значения от ПРЕДЫДУЩЕГО выполнения
  того же SQL — запрос может «работать» на протухших данных или молча
  фильтровать всё (name = NULL). Правило приложения: всегда биндить все
  плейсхолдеры; при raw-SQL использовать `query_one?/query_all` с полным
  набором args. (Выяснено на собственном уроненном аргументе: из-за
  протухшего биндинга это маскировалось под «баг Relation#first?».)

### Известные особенности (Фаза 3, производительность)

- **PRAGMA data_version в WAL двигается только на ЧУЖИЕ коммиты** (другие
  соединения/процессы; no-op UPDATE не считается). Собственные записи
  приложения через пул не инкрементируют его — каждый write-экшен зовёт
  `Campfire::PageCache.invalidate!` явно (MessageCreator, messages#update,
  rooms/bots/profiles/accounts/custom_styles/directs/joins/first_runs).
  Presence-обновления (connected_at) кэш не инвалидируют осознанно.
- **Конкурентные POST**: одиночный POST сообщения ~40 мс, но 16 одновременных
  писателей сериализуются на WAL-записи (26 RPS, mean 600 мс). Для бенча
  (mixed-write-rate ≤ 100/с) не блокер; следить при Фазе 3-тюнинге.
- `render(plain:)` в action_pack сбрасывает статус — 304 передавать
  `status: :not_modified` аргументом (та же ловушка, что в Фазе 1).

**Фаза 3 — веха 2026-10-14: whole-page response cache + gzip + ETag/304.**
- `app/helpers/page_cache.cr` — порт response_cache.js: byte-bounded LRU
  (CAMPFIRE_RESPONSE_CACHE_MB, default 64 MB, max entry = budget/8), epoch
  = PRAGMA data_version (+ invalidate! на своих записях), ключ = handler +
  URL + Accept/Turbo-Frame/User-Agent/Cookie + user_id; страница хранится
  с ETag (SHA1-префикс), gzip-представление лениво; отдача через
  `ApplicationController#send_page` (If-None-Match → 304, Accept-Encoding →
  gzip, Vary).
- Замер (loadgen http, conc=16, 15 c, сид-база, комната All Talk): baseline
  231 RPS / p99 147 мс / 126 KB → **3749 RPS / p99 9 мс / 10 KB (gzip)** —
  ×16. Инвалидация проверена: POST сообщения → следующий GET 200 MISS
  (новое тело), без записи — 304. Browser smoke — PASS.
- Осталось из Фазы 3: fragment cache (message_dom по template digest +
  id + updated_at) для MISS-рендера, прекомпрессия крупных страниц,
  sidebar/searches при необходимости, тюнинг WEB_CONCURRENCY (serverX
  multi-worker) против 1 процесса на фибрах — после подключения serverX.

**Фаза 3 — веха 2 (2026-10-14): главный тормоз был dev-сборкой.** Замеры
велись на бинаре без `--release`; hello 142k из results/000-hello.md —
release-сборка. После `crystal build --release` (бинарь `bin/app-release`):

| Роут | dev | release |
|---|---|---|
| `GET /up` | 15.6k RPS | **75.7k RPS** (p50 0.2 мс) |
| `GET /rooms/:id` (PageCache+gzip) | 3.7k RPS | **13.1k RPS** (p99 2.9 мс) |

От исходного baseline 231 RPS (dev, без кэша) — рост **×56**; уровень Rails
(4.1–4.3k) превышен втрое на одном процессе stdlib HTTP::Server. Browser
smoke на release-бинаре — PASS. **Правило: все бенч-замеры — только на
`--release`** (bin/benchmark и Dockerfile Фазы 4 должны собирать release).

Остаток разрыва до Go (53–60k): (а) 3 SQL на каждый запрос
(session + user + PRAGMA data_version) — кэшировать сессию/юзера per-fiber
или mem-таблицей с инвалидацией по epoch; (б) транспорт stdlib → serverX
(reusePort, WEB_CONCURRENCY=3); (в) fragment cache MISS-рендера. Go- и
Rust-реализации лежат в `~/rails.cr/tmp/once-campfire-{go,rust}` — их
front-server (h2c, bounded response cache) — ориентир для Фазы 3-тюнинга.

**Фаза 3 — веха 3 (2026-10-14): транспорт ServerX + WEB_CONCURRENCY=3.**
- Подключён `serverx` (path-зависимость → ~/serverX.cr; на Фазе 4 — GitHub):
  `CRAILS_TRANSPORT=serverx` в src/app.cr — AppServer (handler = всё
  приложение, cable внутри chain), воркеры — `ServerX::Cluster.run`
  (fork + SO_REUSEPORT, `WEB_CONCURRENCY`), в fork-ребёнке AR-пул и
  jobs-БД переоткрываются (`JobQueue.reset!`).
- **CableBus** (app/helpers/cable_bus.cr): межворкерная шина кабеля —
  TCP-хаб на 127.0.0.1:<app_port+1000>, избираемый bind-конкуренцией;
  `Campfire.broadcast` = локальная доставка + ретрансляция пирам
  (эквивалент cluster-IPC cable-batch у express). Все 5 точек broadcast
  переведены на неё.
- **busy_timeout=10000 в AR sqlite-адаптере** (монорепо, локально):
  без него 3 воркера ловили `database is locked` (500 на GET).
- Сборка: `--release -Dwithout_mt` (fork-воркеры). Итоги (conc=16, 10 c):

| Роут | stdlib×1 | serverX×1 | serverX×3 |
|---|---|---|---|
| `/up` | 75.7k | 79.5k | **183k RPS** |
| `/rooms/:id` (кэш+gzip) | 13.1k | 14.2k | **39.2k RPS** (p99 0.65 мс) |

Browser smoke на serverX×3 — полный PASS (live-сообщения между вкладками
через шину, боты, QR, session transfers, direct pings). От исходного
231 RPS — рост **×170**; до Go-диапазона (53–60k на офиц. стенде 4 ядра)
остаётся ~1.4× — следующий рычаг: мем-кэш сессий (3 SQL/запрос).

Следующий шаг: патч harness (compare.rb: allowed/топология/Dockerfile,
release+serverX+WEB_CONCURRENCY=3 в образе) для формального preflight,
затем мем-кэш сессий.

**Фаза 4 — веха 1 (2026-10-14): git-зависимости, Docker-образ, формальный
preflight — всё зелёное.**
- Все шарды опубликованы на GitHub и тегированы: `railties.cr`/`action_pack.cr`/
  `action_cable.cr`/`turbo.cr`/`active_record.cr` v0.1.1 (патч-бамп для
  `~> 0.1.0`), `rqrcode.cr` v0.1.0, `serverx` v0.2.1, 12 реп монорепо v0.1.0.
  Грабли: теги должны существовать именно на GitHub (ls-remote), branch и tag
  в constraints — разные шарды.
- `shard.yml` приложения полностью на git-зависимостях (симлинков в `lib/`
  нет); `shards install` собирает рабочий бинарь. serverX-ветка читает порт из
  `ENV["HTTP_PORT"]` (harness передаёт его контейнеру).
- Dockerfile: build-стадия `shards install` из публичных реп + `crystal build
  --release -Dwithout_mt` (в build-образе нужны `sqlite-dev yaml-dev zlib-dev
  openssl-dev` — без них линкер падает на `-lsqlite3`); runtime-стадии alpine
  нужны `gc libevent pcre2 sqlite-libs libgcc libstdc++ yaml` — без `yaml`
  бинарь падает `libyaml-0.so.2 not found` сразу после старта (exit 127).
  `bin/docker-build.sh` сведён к `docker build` с контекстом-приложением
  (`.dockerignore`: lib, .git, tmp, `db/*.sqlite3*`, локальные бинари).
- Harness-форк: `allowed += crails`, топология `when "crails"`, образ
  `once-campfire-crails:app` подставляется дефолтом.
- Формальный preflight `bin/benchmark --apps crails --preflight --port 25140`
  — **PASS** (exit 0): 3 раунда, контракты всех 8 роутов сняты
  (room_show gzip 127k→10k байт, avatar/static_css байт-точны),
  `post_write_audit verified`, seed не изменён, `complete: true`.
  Важно: дефолтный порт 25130 занят `campfire-rails-baseline`
  (`0.0.0.0:25130→80/tcp`) — его ready-ответ маскирует падение тестируемого
  контейнера; прогонять с явным `--port`.

Следующий шаг: мем-кэш сессий (3 SQL/запрос: session + user + PRAGMA
data_version), затем полный официальный прогон 3 раундов.

**Фаза 4 — веха 2 (2026-10-14): мем-кэш аутентификации (IdentityCache).**
`app/helpers/identity_cache.cr`: per-worker кэш session+user по токену,
записи живут один DB-epoch (тот же `PRAGMA data_version`, что у PageCache);
`PageCache.invalidate!` сбрасывает и его (все 13 write-экшенов покрыты).
`ApplicationController`: `db_epoch` — мемо PRAGMA на запрос (контроллер
per-request: `klass.new(context)`), аутентификация и page-cache делят одну
эпоху; негативные результаты не кэшируются. Горячий путь /rooms HIT:
3 SQL → 1 PRAGMA. Проверено: login/rooms 200; инвалидация — UPDATE sessions
из чужого процесса → 302 немедленно. Замер (serverX×3, conc=16, без cpuset,
как веха 3): /rooms **39.2k → 77.4k RPS** (×2, p50 0.18 мс, p99 0.56 мс,
0 ошибок) — уровень Go (53–60k) превышен.

Следующий шаг: полный официальный прогон 3 раундов в harness.

**Фаза 4 — веха 3 (2026-10-14): первый полный официальный прогон — PASS
(exit 0, 3 раунда, все роуты, write-аудиты зелёные).** По дороге исправлен
контрактный баг messages_page, который преflight физически не мог поймать
(контракты снимаются, но не валидируются под нагрузкой):
- loadgen route-contract-v1 матчит `<div ... data-message-id=...>` и
  closure `</turbo-frame></div>$` каждого сообщения, а мы рендерили
  минимальный `<article>` — 0 матчей, 100% invalid; Ruby-prepare матчит
  `data-message-id="..."` без div, поэтому preflight проходил;
- фикс: `render_messages_page` → `ChatLayout.message_dom` (тот же DOM,
  что room_show) + убран закрывающий `</main></body></html>` — последний
  сегмент должен кончаться ровно на `</turbo-frame></div>` (messages_page
  — partial истории, полной HTML-страницей быть не обязан).
Замеры официального стенда (cpuset 8-11, conc=16, median из 3 раундов):

| Роут | RPS | | Роут | RPS |
|---|---|---|---|---|
| room_show (PageCache+gzip) | **58 093** | | static_css | 209 000 |
| messages_page | 2 982 | | up | 147 832* |
| sidebar | 11 089 | | post_message | 110 |
| search | 3 915 | | avatar | 3 205 |

*up: 158k/148k/120k (медиана 147.8k; разброс от соседней нагрузки).
room_show 58k — верхняя граница Go-эталона (53–60k) на тех же ядрах;
Rails-эталон /up 2.8k.

Сравнение с эталонами этого стенда (bench/results/600-campfire-baselines.md;
базовые линии снимались на cpuset 0,2,4,6, наш прогон — 8-11, оба 4 P-ядра):

| Роут | Rails | Express | Go | Rust | CRails |
|---|---:|---:|---:|---:|---:|
| room_show | 157 | 19 492 | 26 598 | 52 536 | **58 093** |
| messages_page | 273 | 35 114 | 28 369 | 47 213 | 2 982 |
| sidebar | 360 | 46 383 | 32 843 | 52 574 | 11 089 |
| search | 238 | 35 999 | 29 802 | 51 970 | 3 915 |
| /up | 2 826 | 47 972 | 59 862 | 81 267 | **147 832** |
| static_css | — | — | — | — | 209 000 |

CRails — №1 на room_show и /up; отставание messages_page/sidebar/search —
динамический рендер без whole-page кэша (Rust кэширует всё); следующие
рычаги: PageCache на sidebar/messages_page/search (запросы стабильны в
пределах epoch) и кэш User в message_dom.

**Фаза 2 (cable) — веха 2026-10-14: Action Cable работает end-to-end.**
- Фреймворк-клей (вложенные репо `~/rails.cr`, локально, не публикуется до
  Фазы 4):
  - `turbo.cr`: `Turbo.signed_stream_verifier_key_from_secret!` — деривация
    ключа подписи стримов (PBKDF2-SHA256, 1000 итераций, соль
    `turbo/signed_stream_verifier_key`; вектор в `spec/railtie_key_spec.cr`);
  - `railties.cr`: `Application#cable_handler` — монтаж cable-хендлера ПЕРЕД
    middleware-стеком (аналог ActionCable::Engine; спека
    `spec/cable_mount_spec.cr`); railties НЕ зависит от action_cable_cr
    (приложение подставляет готовый ws_handler);
  - `action_pack.cr`+`action_cable.cr`: фикс Cookie-парсера — элементы без
    `=` (пустой cookie-заголовок loadgen) больше не роняют запрос
    IndexError'ом (семантика Rack: значение "");
  - `action_cable.cr`: CableHandler эхает `Sec-WebSocket-Protocol:
    actioncable-v1-json` в 101 (без этого tungstenite/loadgen отклоняют
    хендшейк; спека в ws_spec.cr).
- Приложение: `config/cable.cr` (единый `ActionCable::Server` →
  `ActionCable.server`/`Turbo.cable_server`/`cable_handler`; `Turbo.app =
  "campfire"`), connection-авторизация по signed-cookie `session_token`
  (identifier `current_user` = id строкой), каналы RoomMessages (gid-стрим +
  проверка membership), Presence (present/absent/refresh → memberships),
  UnreadRooms, Heartbeat; turbo-cable-stream-source на room-странице и в
  сайдбаре (rooms + user:rooms); POST message бродкастит тот же turbo-stream
  кадр в стрим комнаты.
- Верификация: python raw-WS smoke (welcome → 5 подписок → confirm →
  broadcast с маркером) — PASS; реальный loadgen `login → scrape → cable`
  (4 клиента, 2 постера): ready 4/4, failed 0, 2787 постов / 0 ошибок,
  3714 frames/sec, latency-доставка полная. `/` → redirect на последнюю
  комнату (cookie last_room / первая видимая).

**Фаза 2 — ✅ закрыта (2026-10-14): browser gate + jobs-очередь.**

Browser gate (Playwright smoke) зелёной вехой закрыт 2026-10-14: полный PASS
(setup/first_run, two-tab live messaging + duplicate suppression, stored-markup
safety, permalinks, редактирование, поиск, профиль/аккаунт, QR, комнаты
create/rename + broadcast, боты, custom styles, session transfers, join по
invite, autocomplete direct pings). Фиксы финального блока: парсинг
`user_ids[]` (action_pack кладёт их в `params["user_ids"]` как
Scalar/Array/Parameters — `directs_controller#selected_user_ids`), и
pill-template автокомплита с `<img data-content="avatar">` (selection.js
требует; сверен с direct_new.eta).

Jobs-очередь «persisted before response» (порт src/jobs.js express):
- `app/jobs/job_queue.cr` — leased-SQLite очередь в отдельной `db/jobs.sqlite3`
  (WAL, busy_timeout 10 c): enqueue-батч синхронно из HTTP-запроса, claim по
  случайному lease-токену на 120 c, retry с экспоненциальным backoff
  (2^n, кап 300 c), dead после 5 попыток, last_error; inline-воркер —
  JOB_CONCURRENCY фибр (default 3), поллинг 250 мс, стартует вместе с serve;
- `app/models/message_creator.cr` — единая точка создания сообщения:
  insert + ActionText-тело + FTS5 + turbo-stream broadcast + unread_memberships
  (offline >60 c, involvement<>'invisible') + notify (webhook-джобы ботам
  комнаты при direct/упоминании, push-джобы involvement everything/mentions
  offline-участникам) — всё до ответа; sgid-упоминания без проверки подписи
  (порт mentionIds/unverifiedUserGid);
- perform: webhook — POST JSON-payload (user/room/message, path с botKey),
  7-сек таймаут → реплай «Failed to respond...», ответ 200 text/* →
  сообщение от бота (webhooks: false против петель); push — no-op без
  VAPID-ключей (как express), полноценная доставка — Фаза 4;
- `bots_controller` — webhook_url бота теперь сохраняется в webhooks
  (create/update/edit; раньше поле формы игнорировалось);
- проверено end-to-end: бот с webhook на локальный сервер → сообщение с
  sgid-упоминанием → джоба → доставка JSON → реплай «pong from bot» от бота →
  очередь пуста. Регресс: browser smoke PASS.

Осталось: Фаза 4 — мем-кэш сессий, полный официальный прогон 3 раундов,
сравнение по роутам, README.

### Известные особенности (browser gate, Фаза 2)

- **`%("\n)`-ловушка**: в DOM-билдерах повторялась опечатка — незакрытый
  тег `%("\n)` вместо `%(">\n)` (мета current-user-name, message_dom,
  searches#show). После каждого нового DOM-билдера grep `%\("\\n\)` по
  приложению — должен быть пуст.
- **Порядок загрузки `app/controllers/**`** — алфавитный glob: файл,
  идущий раньше `application_controller.cr` (например `accounts_controller`),
  требует явного `require "./application_controller"`.
- **Base64-декодинг**: `Base64.decode` кидает `Base64::Error` (не
  `ArgumentError`) — ловить оба (qr_codes#show).
- **Роутер: `+` в path-сегментах** — action_pack routes.cr декодирует
  сегменты через `URI.decode_www_form` (семантика query), `+` становится
  пробелом. Ловится на join_code с base64-алфавитом; joins_controller
  пробует оба варианта. Правильный фикс — в монорепо (декодировать только
  %XX).
- `Model.new(kwargs)` без `type`; STI-подклассами; UPSERT не работает на
  FTS5 (DELETE+INSERT); integration_spec.cr:137 — старый фейл (параметры
  action/controller утекают в echo), не трогать; loadgen cable перепроверить
  после смены rejection-семантики (подписки валидные — не должно меняться,
  но НЕ проверено).
