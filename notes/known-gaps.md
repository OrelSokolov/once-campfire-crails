# Осознанные отклонения порта от Rails-оракула

Собрано при чистке русских комментариев (фаза 1 плана plans/STYLE_1to1.md):
комментарии в коде убраны ради 1:1, пояснения перенесены сюда.
Синтаксические отличия Crystal — см. notes/style-parity.md.

## Кэширование и инвалидация

- `app/models/response_cache.cr`: PRAGMA data_version из пула не видит
  собственные коммиты приложения — каждый write-экшен зовёт
  `Campfire::ResponseCache.invalidate!` явно (в оракуле отдельный
  readonly-observer на постоянном соединении); `invalidate!` сбрасывает также
  IdentityCache и FragmentCache.
- `app/models/fragment_cache.cr`: per-worker LRU по cache-ключу +
  `RENDER_VERSION`, инвалидация по DB-epoch (PRAGMA data_version) вместо
  `ActiveSupport::Cache::MemoryStore` оракула.
- `app/controllers/concerns/cached_responses.cr`: whole-page кэш — PageCache
  per-worker с инвалидацией по DB-epoch вместо
  `ResponseCache.instance.version`; запись только если эпоха не изменилась за
  рендер и нет `Set-Cookie`; тело отдаётся сырыми байтами; `render(plain:)`
  сбрасывает статус — передаётся аргументом.
- `app/controllers/searches_controller.cr`, `rooms_controller.cr`,
  `messages_controller.cr`: whole-page cache (ключ по query, DB-epoch,
  gzip+ETag/304) вместо `around_action :cache_read_response` + `fresh_when`.
- `app/helpers/identity_cache.cr` / `avatar_cache.cr` / `app/middleware/public_cache.cr`:
  публичный кэш свеж только по TTL из Cache-Control (смена аватара видна до
  30 минут); кэш наполняет AvatarsController, т.к. stdlib Response не даёт
  middleware перехватить тело чужого ответа.

## SQLite / конкурентность (WriteQueue, JobQueue)

- `app/helpers/write_queue.cr`: двухуровневая очередь — единственная
  writer-фибера в процессе (livelock busy-хендлера SQLite) + robust
  process-shared мьютекс; страница и мьютекс создаются в master до fork.
- `app/models/message_creator.cr`: транзакция и постановка джобов через
  WriteQueue; джобы ставятся строго ПОСЛЕ commit production-транзакции
  (ожидание write-lock очереди внутри транзакции — дедлок при conc=16);
  `retry_on_lock`: транзакции `BEGIN IMMEDIATE` (как Rails 8.1 sqlite3).
- `app/jobs/job_queue.cr`: flock для межпроцессной сериализации писателей;
  WAL обязателен (DELETE-журнал в fork-конфигурации ловил "readonly
  database"), `wal_autocheckpoint=0` + PASSIVE-чекпоинт-фибера;
  `BEGIN IMMEDIATE` + `retry_on_lock`; `reset!` после fork (serverX Cluster).

## Action Cable / трансляции

- `app/models/current.cr`: `delegate :host, :protocol, to: :request` оракула
  невоспроизводим — CurrentAttributes порта class-level only (instance-API и
  method_missing-форвардинг не портированы); остаются ручные
  `self.request_host` / `self.request_protocol`.
- `app/models/membership/connectable.cr`: scope-ы :connected/:disconnected
  объявлены в membership.cr (Crystal `scope` — только в теле класса);
  `connected_at?`-предиката нет — nil-чтение прямо в `connected?`;
  `Time.utc - TTL` вместо `CONNECTION_TTL.ago` (`.ago` не портирован).
- `app/channels/presence_channel.cr`: `membership` ищется через
  `find_by(user_id:)` (объект в kwargs-where невыделяем);
  `Campfire::ResponseCache.invalidate!` в `present` — см. кэширование.
- `app/models/user.cr`: scope `visible_to` объявлен в теле User, не в
  User::Bannable (ограничение `scope`-макроса).

- `app/channels/application_cable/connection.cr` (+ channel.cr): cable
  identifiers хранятся строками (user id как String).
- `app/channels/concerns/room_streams_are_authorized.cr`: Crystal без
  `prepend` — класс reopened с guard, тело базового `#subscribed`
  продублировано (нет `super`).
- `app/helpers/cable_bus.cr`: запись в сокет только через writer-фиберу
  (прямые записи из многих фибер — интерливинг partial write(2));
  клиентская доставка напрямую в pubsub (иначе эхо-петля).
- `app/models/message/broadcasts.cr`: `chomp` хвостового `\n` у `message_dom`
  (Erubi в Rails глотает переводы строк после `<% end %>`).
- `app/controllers/messages/boosts_controller.cr` (+ by_bots): `\n` партиала
  `_boost.html.erb` добавляется к html вручную; touch сообщения при
  create/destroy буста — вручную (belongs_to `touch: true`).

## STI комнат

- `app/models/room.cr` (+ membership, sidebars, chat_layout): type хранится в
  двух написаниях — полный из сидов оракула (`Rooms::Open`), короткий при
  создании портом (`Open`); все scope расширены до `IN` обеих форм;
  `direct?` — по `rooms.name IS NULL`, не по type.
- `app/models/room.cr#to_gid_param`: gid строится от STI-класса записи с
  нормализацией короткого type к полному (иначе расходится
  signed-stream-name turbo-cable-stream-source).

## Аутентификация / безопасность

- `app/controllers/concerns/authentication.cr`: CSRF отключается только
  успешно аутентифицированным bot-ключом; `__csrf_token_field` всегда `""`
  (ленивые сессии оракула рендерят формы без embedded token, верификация
  header_only по Sec-Fetch-Site); `remote_ip` верит `X-Forwarded-For` только
  при доверенном пире (loopback/private/CGNAT); signed_id — MessageVerifier
  `"active_record/signed_id"`, Rails 8.1 urlsafe-формат, sha256 + sha1
  fallback для legacy express-токенов; origin из `X-Forwarded-Proto`.
- `app/models/user/avatar.cr` / `user/transferable.cr`: верификатор sha256 с
  sha1-fallback (legacy express).
- `app/models/user/bot.cr`: `authenticate_bot` — constant-time сравнение
  (`Crypto::Subtle`), не SQL-строкой.
- `app/models/user.cr`: dummy-bcrypt `DUMMY_BCRYPT` реплицирует timing-защиту
  `authenticate_by`.
- `app/models/message/mentionee.cr`: sgid-подпись User НЕ проверяется (ротация
  SECRET_KEY_BASE не ломает упоминания); non-User → nil.
- `app/controllers/users/avatars_controller.cr`: токен-путь публичен
  (`skip_before_action :require_authentication`); опасные content-types
  форсируются в octet-stream/attachment (stored XSS); ключ подписи совместим
  с campfire-express `rails.js`.

## Сеть / fetch

- `app/models/opengraph.cr` (+ fetch.cr): гем `restricted_http` заменён
  DNS-резолвом с пиннингом (все адреса хоста обязаны быть публичными, fail
  closed; коннект к проверенному IP, TLS/SNI по имени) — закрывает
  DNS-rebinding; workaround Crystal 1.21 — `Socket::Addrinfo.resolve` требует
  явный `type: STREAM`.
- `app/models/opengraph/metadata.cr`: декод entities циклом `Regex#match`
  (gsub-блок с группами в Crystal 1.21 возвращает мусорный `MatchData#[]`).
- `app/jobs/web_push.cr`: криптография через libcrypto напрямую (stdlib не
  экспортирует ECDH/ES256/GCM-тег); SSRF-фильтр resolvePublic (DNS-pinning,
  только публичные адреса, только https).
- `app/controllers/unfurl_links_controller.cr`: дедлайн передаётся вниз
  инкрементально на каждый connect/read/write; ошибка сети → nil → 204
  (вместо `Timeout.timeout` + warn-лога).
- `app/controllers/users/push_subscriptions/test_notifications_controller.cr`:
  доставка синхронная через `WebPush.deliver` (у референса пул); без
  VAPID-ключей — no-op; 404/410 удаляют подписку.

## Контроллеры и рендер

- `app/controllers/application_controller.cr`: `Turbo::Streams::Broadcasts`
  подключается вручную (в Rails это делает turbo-rails engine).
- `app/controllers/messages_controller.cr`: `MAX_UPLOAD_BYTES` — верхний
  лимит multipart-тела (защита от DoS); файловые части парсятся
  action_pack_cr ≥ 0.2.13 в params как `ActionController::UploadedFile`
  (ручной парсер удалён); nil-narrowing-воркараунд (`target = message`)
  для замыкания WriteQueue.
- `app/controllers/messages/by_bots_controller.cr`: HTTP-ответ create —
  turbo-stream append, а не `head :created, location:` (следует
  express-референсу); `created_at` биндится только подзапросом (прямое
  связывание Time даёт RFC3339, расходится с форматом колонки).
- `app/controllers/messages/boosts/by_bots_controller.cr`: 422 =
  `:unprocessable_content`; лимит ≤16 code points (express-контракт).
- `app/controllers/rooms_controller.cr`: сравнение по `created_at` —
  субзапрос по id (литеральный Time-бинд sqlite3-шарда сериализуется с
  миллисекундами, якорь deep-link дублировался).
- `app/controllers/concerns/authorization.cr`: метод называется
  `require_admin`, ответ `render(plain: "forbidden", status: 403)` вместо
  `head :forbidden` (тело ответа отличается).
- `app/controllers/concerns/tracked_room_visit.cr`:
  `remember_last_room_visited` вызывается вручную после решения page-cache, а
  не before_action; принимает room аргументом.
- `app/controllers/rooms/directs_controller.cr`: `page_head` не назван `head`
  — перекрыл бы фреймворковый `head(status)`.
- `app/controllers/autocompletable/users_controller.cr`: NoTemplateDedent —
  вывод сохраняет отступы шаблона (parity-бейзлайны их фиксируют).
- `app/controllers/qr_code_controller.cr`: PNG через rqrcode_cr вместо SVG
  оракула, без `expires_in 1.year`.
- `app/controllers/welcome_controller.cr`: fallback — первая видимая комната
  по id, а не `Current.user.rooms.original`.
- `app/controllers/joins_controller.cr`: роутер декодирует path-сегменты
  через `URI.decode_www_form`, «+» в join_code превращается в пробел —
  пробуются оба варианта.
- `app/controllers/accounts/logos_controller.cr`: `show` вручную реализует
  `stale?`/`expires_in` (ETag `W/"account-logo-<blob-key|stock>"`);
  `destroy` вручную чистит variant records, blob и файлы variants.
- `app/controllers/accounts/bots_controller.cr`: `destroy` жёстко удаляет
  memberships + webhooks + бота вместо `deactivate` оракула.
- `app/controllers/sessions/transfers_controller.cr`: PUT/PATCH обработан в
  `create` (у оракула `update`); cookie session_token на 20 лет.

## Модели

- `app/models/message/pagination.cr`: Rails `Page < Array` невозможен в
  Crystal (дженерики не наследуются) — возвращается `Array(Message)`.
- `app/models/message/attachment.cr`: вложение — прямая вставка blob +
  attachments + touch; variants `:thumb`/`:poster` (vips/ffmpeg) не
  портированы; анализ изображения синхронный внутри транзакции.
- `app/models/membership.cr`: `Relation#joins` по belongs_to не поддержан —
  сырые JOIN-фрагменты; строковый `ar_enum` с lenient-чтением из БД.
- `app/models/account.cr`: `has_json :settings` вручную; `logo_variant` —
  nil при ошибке vips → контроллер отдаёт сток-иконку.
- `app/models/first_run.cr`: `join_code` — base64url без padding (по express
  routes.js), а не `alphanumeric(12)` группами по 4.
- `app/models/application_platform.cr`: инлайн мини-порта useragent;
  `apple_messages?` в порте `||`, в оракуле `&&` — проверить отдельно.
- `app/models/user/bannable.cr`: `close_remote_connections` ПОСЛЕ commit
  (рано закрытый сокет реконнектится и перечитывает живую сессию).
- `app/models/room/message_pusher.cr`: WebPush.deliver → nil для
  не-https/private адресов → skip.
- `app/jobs/bot/webhook_job.cr`: ответ бота — `webhooks: false` (аналог
  `notifyMessage(result, { webhooks: false })` express).
- `app/jobs/**`: ActiveJob-слой — макрос `serialized(**args)` вместо
  неявной сериализации Rails; `Bot::WebhookJob` принимает
  `webhook_id : Int64` + `message` (модели Webhook нет; оракул шлёт
  `perform(bot, message)`); логика джоб осталась в джобах, а не в моделях
  (`bot.deliver_webhook` и пр.) — перенос запланирован отдельно (1to1_new,
  фаза 3). Kind-строки Campfire::JobQueue ("push"/"webhook"/...) —
  стабильный контракт поверх pending-джоб в БД-очередях.

## Хелперы / вьюхи

- `app/helpers/users_helper.cr` / `accounts_helper.cr`: nav-ссылки —
  литеральные `<a>`: `link_to` ставит href последним, у оракула href первый
  (byte-parity).
- `app/helpers/boosts_helpers.cr`: шаблон boosts/index без завершающего `\n`
  (byte-parity: `boosts_dom` сам завершает вывод `\n`).
- `app/helpers/users/avatars_helper.cr`: цвет аватара `Digest::CRC32` вместо
  `Zlib.crc32` (байт-в-байт идентичен Ruby).
- `app/helpers/messages_helper.cr`: `messages_page_html` — DOM записи =
  `message_dom` комнаты; отдача через fragment-кэш, авторы промахов — одним
  IN-запросом.
- `app/helpers/html_sanitizer.cr`: один проход с объединённым allowlist
  вместо трёх санитайзер-слоёв оракула; применяется в той же точке.
- `app/helpers/chat_layout.cr`: CSRF_TOKEN — случайное значение на процесс
  (сервер CSRF не проверяет); `text_presentation` срезает
  `data-highlight-language` (race lexxy/hljs) для детерминированного паритета.
- `app/helpers/users/sidebar_helper.cr`: сортировка комнат в Crystal, не
  SQL-скопами — детерминированный порядок при равных `updated_at`.
- `app/helpers/users/profiles_helper.cr`: у User нет FormModel —
  `profile_form_with` передаёт значения явным `value:`.
- `app/views/**/*_json.jbuilder`: `as_local:` вместо `as:`; `json.jb_origin`
  передаёт base URL (у оракула route-хелперы); нет `json.cache!`.
- `app/views/messages/_message.json.jbuilder`: `html` обёрнут в
  `<div class="lexxy-content">`; `plain_text` при пустом теле — имя файла
  вложения.
- `app/views/autocompletable/users/_user.json.jbuilder`: дополнительные поля
  `id`, `label`, HTML-экранированное `name` (serialization contract
  `routes.js registerUsers`).

## Прочее

- `app/controllers/concerns/version_headers.cr`: X-Version/X-Rev из ENV
  (аналог инициализатора version.rb), не из `Rails.application.config`.
- `app/controllers/accounts/custom_styles_controller.cr`: `update` без
  `notice: "✓"` в redirect_to (flash не портирован); тест гонку Turbo-редиректа
  закрывает маркером data-parity-sent.
- `app/helpers/**`: helper wiring через action_pack 0.2.14 (маркер
  `include ActionController::Helper` + конвенция/`helper :sym`) вместо
  Rails include-all: 8 конфликтов имён между crails-обёртками
  (page_open/page_close/copy_button/avatar_link/last_room_visited_path/
  fresh_account_logo_path/translation_button/version), у оракула этих
  методов в хелперах нет (page_open и пр. — crails-обёртки над ChatLayout);
  `helper :all` разблокируется после переноса HTML в ERB-партиалы.
  `helper_method` — compile-валидация без рантайм-эффекта (контекст рендера
  = контроллер); оракульные `platform`/`signed_in?`/`last_room_visited`
  не портированы (crails-хелперы несут свою логику platform через @ua).
- `app/controllers/first_runs_controller.cr`: avatar в permit-списке для
  паритета, но загрузка не портирована — FirstRun игнорирует поле.
- `app/controllers/rooms/involvements_controller.cr`: `update` не делает
  `broadcast_visibility_changes` оракула — проверить, известен ли гэп.
