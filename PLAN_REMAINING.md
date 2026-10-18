# Оставшиеся работы — CRails / once-campfire-crails

Дополняет `plans/completed/PLAN.md`: задачи, появившиеся после основного цикла порта.
Формат тот же — что/зачем/оракул/шаги/критерии готовности.

## 1. `image_processing` / `active_storage.cr` — картинки и вложения

> Обновлено: шард `OrelSokolov/active_storage.cr` (Iteration 8, master,
> 3b75b1d) с `image_processing_cr` (vips/mini_magick) подключён к
> приложению (`shard.yml`; до пуша тегов v0.1.1 / marcel v2.1.0 /
> image_processing v1.14.0 — `branch: master` + `shard.override.yml`).

### Сделано

- `MessageCreator.store_attachment` — `Blob.create_and_upload!`
  (ключ 24 base62, md5-checksum, файл через DiskService);
  metadata width/height — интерим-парсером заголовков
  `app/models/image_dimensions.cr` (PNG/JPEG/GIF/WebP);
- `ActiveStorageController#representation` — реальный ресайз через
  `ActiveStorage::Variation` (vips): кеш
  `variants/<blob.key>/<variation.key>` на диске, ошибка обработки →
  отдача оригинала; отдача файлов — через `DiskService#path_for`
  (фан-аут гема; подкласс `CampfireDiskService` в
  config/application.cr, пока в шарде плоский путь);
- рендер вложений — размеры из metadata блоба + обёртка
  `inline_media_dimension_constraints` (половина превью, 1:1 с
  Messages::AttachmentPresentation референса).

### Осталось

- **Analyzer в шарде** — план: `~/myshards/active_storage.cr/
  ANALYZER_REMAINING.md` (blob.analyze! → metadata
  `{"width":…,"height":…,"analyzed":true}`; после — удалить интерим
  `app/models/image_dimensions.cr` из приложения).
- `Account#logo_variant(:large 512 / :small 192)` + `LogosController`
  — варианты логотипа вместо оригинала (теперь просто
  `blob.variant(resize_to_limit: …)` шарда).
- `Dockerfile`: build `apk add vips-dev`, runtime `apk add vips`;
- тег `v0.1.1` шарда → `version: ~> 0.1.1` в shard.yml, удалить
  `shard.override.yml`.

### Отклонения от 1 к 1 (актуальные)

- Байты вывода vips не воспроизводимы байт-в-байт с Rails-эталоном;
  контракт — валидность + размеры + формат.
- Идемпотентность вариантов — по наличию файла
  `variants/<key>/<variation.digest>` в сервисе; таблица
  `active_storage_variant_records` (в схеме есть) не используется —
  у гема она для отслеживания в БД; при необходимости добить позже.
- `DiskService#path_for` — плоский (в геме фан-аут
  `key[0,2]/key[2,2]/key`); обойдено подклассом в приложении,
  фиксится в шарде (см. ANALYZER_REMAINING п. 4).

## 2. Web Push — подписки, доставка, service worker

### Почему

Push в порте — стаб: `app/jobs/job_queue.cr:257-259` при заданных
`VAPID_*`-ключах печатает `not implemented` и выходит; эндпоинтов
`/users/me/push_subscriptions` нет в `config/routes.cr` вовсе (JS-колокол
`_bell.html.erb` на них ссылается); `GET /service-worker` не портирован
(заявлено в `app/controllers/pwa_controller.cr:5`). Реализовано во всех
шести остальных портах (express `jobs.js:394`, rust `web_push`-пул,
go `Push.VAPID`, elixir `web_push.ex`, c, dotnet `Workers/Push*`).

### Оракул (upstream)

| Файл | Роль |
|---|---|
| `app/controllers/users/push_subscriptions_controller.rb` | index/create/destroy подписок (params: endpoint, p256dh_key, auth_key; user_agent) |
| `app/controllers/users/push_subscriptions/test_notifications_controller.rb` | тестовая доставка |
| `app/models/push/subscription.rb` | валидация endpoint: https + порт 443 + whitelist хостов (FCM/Mozilla/APNs/Windows), резолв IP без private-сетей (rebinding-guard) |
| `app/models/room/message_pusher.rb` | фильтр получателей: involvement everything ИЛИ mentions+mentionees; исключая создателя и connected-пользователей |
| `app/jobs/room/push_message_job.rb` + `web-push` гем 3.1.0 | доставка: WebPush::Notification, VAPID JWT ES256, пул `config.x.web_push_pool` |

### Что делать

1. Крипто-минимум для RFC 8291/8292 без гемов: ECDH P-256 +
   HKDF + AES128GCM шифрование payload; VAPID-подпись JWT ES256
   (`openssl` C-bindings, как `bcrypt`-шард). Эталоны: `web_push.ex`
   (elixir, порт без зависимостей) и rust-FFI-стиль.
2. `PushSubscription`-модель + миграция таблицы `push_subscriptions`
   (schema.yml референса), валидация как в `push/subscription.rb`
   (whitelist хостов оставить, IP-guard — упрощённо: DNS-резолв
   без link-local/private адресов).
3. Роуты: `/users/me/push_subscriptions` (GET/POST/DELETE),
   `/users/me/push_subscriptions/:id/test_notifications` (POST).
4. `perform_push` в `job_queue.cr`: фильтр получателей из
   `message_pusher.rb`, сборка payload (title/body/path:
   direct — имя создателя, shared — имя комнаты), доставка
   через пул соединений; 404/410 от endpoint → удаление подписки.
5. `GET /service-worker` — статика из `public/` референса.
6. Ключи — ENV `VAPID_PUBLIC/PRIVATE_KEY`, `VAPID_SUBJECT`; без них
   доставка — успешный no-op (как сейчас и как в express).

### Критерии готовности

- [ ] POST подписки с валидным endpoint — 200; с http/non-443/
      не-whitelist хостом — 422;
- [ ] сообщение в комнате с участником involvement=everything,
      имеющим подписку, триггерит доставку (мок endpoint в тесте);
- [ ] 410 от endpoint удаляет подписку;
- [ ] `/service-worker` отдаёт JS референса;
- [ ] без VAPID-ключей поведение не меняется (no-op, RPS без регресса).

## 3. Unfurl / OpenGraph-превью ссылок

### Почему

`POST /unfurl_link` и модели Opengraph не портированы: вставить новую
ссылку с превью нельзя. Рендер готовых `opengraph-embed`-вложений есть
(`chat_layout.cr:512`), т.е. сид-данные отображаются. Реализовано во
всех портах (express `opengraph.js`, rust/go/c/elixir — свои парсеры).

### Оракул (upstream)

| Файл | Роль |
|---|---|
| `app/controllers/unfurl_links_controller.rb` | `POST ?url=` → JSON opengraph или 204; общий дедлайн 10с (DNS/редиректы/страница/картинка) |
| `app/models/opengraph/metadata.rb` + `metadata/fetching.rb` | `from_url`: og-теги → заголовок/описание/картинка, `valid?` |
| `app/models/opengraph/fetch.rb`, `location.rb`, `document.rb` | HTTP-клиент с редиректами, same-/private-network guard, лимит тела |

### Что делать

1. HTTP-клиент: редиректы (лимит как в референсе), таймаут на весь
   запрос 10с, лимит размера тела; host-валидация как `location.rb`
   (без private-IP — тот же консерватизм, что в §2).
2. Парсер og-тегов: `<meta property="og:*">` + fallback на `title`;
   проверка картинки (content-type, размеры) — как `metadata/fetching.rb`.
3. Роут `POST /unfurl_link` → JSON `{ title, description, image, url }`
   (контракт — express `opengraph.js` + JS-клиент референса) либо 204.

### Критерии готовности

- [ ] `POST /unfurl_link?url=<страница с og-тегами>` → 200 + JSON;
      без og-тегов → 204; недоступный URL → 204 в пределах 10с;
- [ ] векторы unfurl из express-порта проходят;
- [ ] private-IP/localhost URL отклоняются.

### Отклонения от 1 к 1

- Гем-стек upstream (`opengraph` + http-гемы с Surfguard) заменён
  собственным клиентом; контракт — JSON-форма express-порта.

## 4. Управление пользователями аккаунта (`/account/users`)

### Почему

`resources :users` внутри `resource :account` не портированы: нет
списка участников, смены роли (member/administrator), деактивации.

### Оракул

- `app/controllers/accounts/users_controller.rb`: `index`
  (`User.visible_to(Current.user).ordered.member`, пагинация 500/стр),
  `update` (role ∈ member/administrator), `destroy` (`user.deactivate`).
- `app/models/user/bannable.rb`: `visible_to` — админ видит
  active+banned, прочие — только active.

### Что делать

1. Роуты `/account/users` (GET), `/account/users/:id` (PATCH, DELETE).
2. `ensure_can_administer`-гвард (сверить `authorization.rb`
   референса с портом).
3. Вьюха index — перенос `app/views/accounts/users/index.html.erb`
   (+ пагинация как в остальных списковых страницах порта).

### Критерии готовности

- [ ] не-админ получает 403 на все три действия;
- [ ] PATCH role обновляет роль и редиректит в `/account/edit`;
- [ ] DELETE деактивирует, пользователь исчезает из `visible_to`
      не-админов.

## 5. Баны пользователей (+ RemoveBannedContentJob)

### Почему

`POST/DELETE /users/:id/ban` и снос контента забаненного не
портированы; порт умеет только рендерить статус `banned`
(`users_controller.cr:20`).

### Оракул

- `app/controllers/users/bans_controller.rb`: create → `user.ban`,
  destroy → `user.unban`, редирект на пользователя; гвард admin.
- `app/models/user/bannable.rb`: `ban` — транзакция (bans из сессий,
  `banned!`), `unban` — `bans.delete_all` + `active!`;
  `remove_banned_content_later` → джоба.
- `app/jobs/remove_banned_content_job.rb`: destroy всех сообщений
  + broadcast_remove каждого.
- Таблица `bans` уже есть в `db/schema.yml` порта.

### Что делать

1. Роуты `POST /users/:user_id/ban`, `DELETE /users/:user_id/ban`.
2. Методы `ban/unban` на User-модели порта (транзакционно).
3. Джоба `remove_banned` в `job_queue.cr`: удаление сообщений +
   Turbo-broadcast remove по каждому (цикл как в джобе референса).

### Критерии готовности

- [ ] бан: status=banned, запись в `bans`, вход запрещён;
- [ ] контент удаляется асинхронно, messages_count комнат
      корректен (сверить с `room/messages_count.rb`);
- [ ] unban возвращает active, push-подписки сохранены (см.
      комментарий в `message_pusher.rb`).

## 6. Ротация join-кода (`POST /account/join_code`)

### Почему

`resource :join_code, only: :create` не портирован: код читается
(`accounts_controller.cr:85`), ротировать нельзя.

### Оракул

`app/controllers/accounts/join_codes_controller.rb` —
`Current.account.reset_join_code`, redirect → edit_account; гвард admin.

### Что делать

Роут `POST /account/join_code` + `reset_join_code` на Account
(генерация как в `account/joinable.rb`), редирект в `/account/edit`.

### Критерии готовности

- [ ] не-админ — 403; после POST старый код даёт 404 на `/join/:code`,
      новый — страницу регистрации.

## 7. Ротация ключа бота (`PUT /account/bots/:id/key`)

### Почему

`resource :key, only: :update` внутри `resources :bots` не портирован.

### Оракул

`app/controllers/accounts/bots/keys_controller.rb` —
`User.active_bots.find(...).reset_bot_key`, redirect → account_bots.

### Что делать

Роут `PUT /account/bots/:bot_id/key` + `reset_bot_key`
(сброс `bot_token`, генерация как при создании бота в
`bots_controller.cr` порта), редирект на список ботов.

### Критерии готовности

- [ ] после ротации старый bot_key даёт 401 на Bot-API, новый
      работает; не-админ — 403.

## 8. `GET /rooms/:id/settings`

### Почему

`resource :settings, only: :show` (`config/routes.rb:75`) не
портирован — страница настроек уведомлений комнаты. В express —
алиас involvement-обработчика (`routes.js:597`: общий handler для
`/rooms/:id/involvement` и `/rooms/:id/settings`).

### Что делать

Добавить `get "/rooms/:room_id/settings"` → `rooms#involvement`
(GET-ветка существующего экшена, контракт express).

### Критерии готовности

- [ ] `/rooms/:id/settings` и `/rooms/:id/involvement` отдают
      идентичный HTML для одного пользователя.

## 9. Bot-API: update/destroy сообщений, destroy бустов

### Почему

Rails даёт ботам полный CRUD (`resources :messages, controller:
"messages/by_bots", only: %i[ index create update destroy ]` и
`boosts ... only: %i[ create destroy ]`). Порт закрыл только
index/create/show сообщений и create бустов (`routes.cr:76-81`).

### Оракул

`app/controllers/messages/by_bots_controller.rb` — update/destroy
с той же bot-аутентификацией (`id-bot_token` в `:bot_key`),
broadcast/редиректы как у человеко-эндпоинтов.

### Что делать

1. Роуты: `patch/put/delete /rooms/:id/:bot_key/messages/:message_id`,
   `delete /rooms/:id/:bot_key/messages/:message_id/boosts/:boost_id`.
2. Экшены `bot_update/bot_destroy` (сообщение) и `bot_destroy` (буст)
   поверх существующей bot-аутентификации в `messages_controller.cr`
   / `boosts_controller.cr`; broadcast-циклы переиспользовать.

### Критерии готовности

- [ ] бот редактирует и удаляет своё сообщение (broadcast
      применяется), чужое — 403/404 по контракту референса;
- [ ] бот снимает буст; неверный bot_key — 401.
