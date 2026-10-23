# План: структурный паритет с Rails-оракула (missing-файлы группы `code`)

> **Статус (2026-10-23):** Фазы A–G выполнены. `twinshot review code`:
> missing 375 → 301 (в `app/`: 138 → 65; остаток — задокументированные
> категории: view-слой собирается compile-time в ChatLayout/ChatERB,
> мейлер, пагинация accounts/users, RecordCache/Purchaser/
> MessagesCount — см. notes/style-parity.md). Rails-инфра без Crystal-
> аналога (bin/*, puma/resque/brakeman, config/environments,
> config/initializers, hooks, lib/*, script/*, bench/*) добавлена в
> soft_check twinshot.yml. Поведенческие проверки: `crystal build`
> зелёный; harness 72 runs / 0 failures. Детали — в конце файла
> («Результат»).

> Базлайн `twinshot review code` (2026-10-22): 856 файлов, 196 pass / 249 warn /
> 411 fail, из них **375 missing in current** (229 вне soft_check, 138 в `app/`).
> Продолжение `plans/style-parity-rails.md` (стилевые диффы существующих
> файлов) — здесь закрываем **отсутствующие пути**: каждый файл оракула должен
> иметь Crystal- counterpart по тому же относительному пути.

Принципы:

- Функциональность уже есть в порте → **перемещаем/переименовываем** в файл
  оракула (модуль получает имя оракула: `MessagesHelper`, `User::Role` и т.п.).
- Функциональности нет и она дёшево реализуема (клиент уже ждёт) → создаём.
- Функциональность — Rails-инфраструктура без смысла на Crystal (bin/rails,
  puma, resque, brakeman…) → **soft_check** в `twinshot.yml` с обоснованием.
- Реально отсутствующее/невоспроизводимое → фиксируем в `notes/style-parity.md`.
- После каждой фазы: `rake build:crails` + `twinshot review default` (AGENTS.md).

## Фаза A — helpers: сингулярные имена как в оракуле (~11 missing)

Переименования (файл + модуль + `include` в контроллере + require в `src/app.cr`):

| current | → oracle-путь |
|---|---|
| `view_helpers.cr` (`ViewHelpers`) | `application_helper.cr` (`ApplicationHelper`) |
| `accounts_helpers.cr` | `accounts_helper.cr` |
| `messages_helpers.cr` | `messages_helper.cr` |
| `rooms_helpers.cr` | `rooms_helper.cr` |
| `searches_helpers.cr` | `searches_helper.cr` |
| `users_helpers.cr` | `users_helper.cr` |
| `avatars_helpers.cr` | `users/avatars_helper.cr` (`Users::AvatarsHelper`) |
| `profiles_helpers.cr` | `users/profiles_helper.cr` (`Users::ProfilesHelper`) |
| `sidebars_helpers.cr` | `users/sidebar_helper.cr` (`Users::SidebarHelper`) |

Новые файлы переносом из ChatLayout: `emoji_helper.cr` (REACTIONS),
`translations_helper.cr` (TRANSLATIONS + translation_button).

Прочие хелперы оракула (cable, clipboard, drop_target, forms, qr_code, rich_text,
time, broadcasts) живут инлайн в ChatLayout/вьюхах — не плодить пустышки;
маппинг уже зафиксирован в `notes/style-parity.md` (дополнить таблицей).

## Фаза B — models: самостоятельные файлы (~13 missing)

- `misc.cr` разложить: `account.cr`, `ban.cr` (+`self.banned?(ip)` — SQL из
  `block_banned_requests.cr` переноcится в модель), `boost.cr`, `search.cr`,
  `webhook.cr`; `misc.cr` удалить.
- `sound.cr` — каталог звуков из `chat_layout.cr:1000-1099` (`Sound::Image`,
  BUILTIN, `find_by_name`); ChatLayout оставляет обёртку `message_sound`.
- `application_record.cr` — abstract-база, перевести все модели на неё
  (шард поддерживает abstract-посредников, `active_record_cr/base.cr:676`).
- `application_platform.cr` — перенос `platform_agent.cr` (класс PlatformAgent
  сохранить, комментарий о слиянии base+subclass).
- `push.cr` (`module Push`) + `push/subscription.cr` (`Push::Subscription`,
  **обязателен `set_table_name "push_subscriptions"`**; alias `PushSubscription`);
  относительный require `../jobs/web_push` → `../../jobs/web_push`.
- `fragment_cache.cr` → `app/models/fragment_cache.cr`;
  `page_cache.cr` → `app/models/response_cache.cr` (класс `ResponseCache`,
  alias `Campfire::PageCache` на переходный период); убрать requires из
  `src/app.cr`.
- `record_cache.cr`, `purchaser.cr` — потребителей нет → `notes/`, не создавать
  пустышек (создать Purchaser минимально? — нет, в оракуле тоже мёртвый код).

## Фаза C — models: concerns по файлам оракула (~20 missing)

Механика (проверена): glob `app/models/**` сортирует лексически, `user.cr`
загружается раньше `user/avatar.cr`; include делаем **в конце concern-файла**
через reopen (`class User; module Avatar; …; end; include Avatar; end`).
Scopes/class-методы, которые нельзя унести в модуль без `class_methods`,
остаются в корневом файле (фиксируем в notes) либо через
`ActiveSupport::Concern` из `lib/active_support_cr` (уже используется:
`membership.cr:7` include Turbo::Broadcastable).

- `user/`: `role.cr` (enum+can_administer? из user.cr), `bannable.cr`,
  `bot.cr`, `avatar.cr` (token/variant, SQL из avatars_controller),
  `transferable.cr`, `mentionable.cr` (константы+plain_text_representation).
- `message/`: `attachment.cr` (UploadedFile+store_attachment из
  message_creator), `broadcasts.cr` (broadcast/broadcast_remove),
  `mentionee.cr` (mention_ids), `searchable.cr` (match_terms, index upsert/
  delete — консолидация SQL из контроллеров), `pagination.cr` (PAGE_SIZE,
  page-методы; `Page < Array` невозможен — обёртка, зафиксировать).
- `room/`: `message_pusher.cr` (реципиенты+payload из job_queue perform_push).
- `membership/connectable.cr` — present/connected SQL из presence_channel.
- `account/joinable.cr` — генерация join-code из join_codes_controller.
- `opengraph/`: split `opengraph.cr` → `location.cr`, `fetch.cr`,
  `document.cr`, `metadata.cr`, `metadata/fetching.cr`; корень остаётся
  namespace-файлом (public_ip?/public_host? — аналог restricted_http, deviation).
- `room/messages_count.cr` — колонки нет, триггеров нет → notes.
- `models/concerns/.keep` — создать для parity дерева.

## Фаза D — channels + jobs (10 missing)

Каналы: `room_channel.cr` (база: find_room по membership + stream_for; из
`presence_channel.cr:31-40`), `read_rooms_channel.cr` (stream_from
`user_X_reads`; клиент уже подписан), `typing_notifications_channel.cr`
(start/stop → broadcast_to @room; JS-клиент уже портирован),
`concerns/room_streams_are_authorized.cr` — в Crystal нет `prepend`, поэтому
reopen `Turbo::StreamsChannel#subscribed` с guard
`RoomMessagesChannel.guarded_stream?` (проверка суффикса `:messages`);
требует `require "../room_messages_channel"` внутри файла (glob-порядок).

Джобы: `application_job.cr` (abstract base), `remove_banned_content_job.cr`,
`bot/webhook_job.cr`, `room/push_message_job.cr` — перенос `perform_*` из
`job_queue.cr` в классы, `JobQueue.perform` → dispatch-case.
`room/destroy_job.cr` — destroy_later: контроллер собирает former_member_ids,
джоб сбрасывает remote-connections и удаляет сообщения по одному + чистит
boosts/rich_texts/FTS (сейчас bulk DELETE с orphan-строками — реальный баг).
`message/broadcast_unread_room_job.cr` — fanout на `user_X_unreads`
(`{roomId, at}` — клиент `rooms_list_controller.js` уже ждёт; сейчас поток
мёртв). Новые kind-строки в JobQueue + enqueue в MessageCreator#notify.

## Фаза E — controllers/concerns (8 missing)

- `raw_request_body.cr` — 4 инлайна `request.body…` в messages*-контроллерах.
- `version_headers.cr` — X-Version/X-Rev из ENV (APP_VERSION/GIT_REVISION).
- `authentication/session_lookup.cr` — split authentication.cr.
- `active_storage_authentication.cr` — из active_storage_controller.cr:32-35.
- `room_scoped.cr` — консолидация set_room (rooms/messages/opens/closeds).
- `allow_browser.cr` — гейт по UA-версиям + `sessions/incompatible_browser`
  (создаётся и вьюха, см. Фаза F).
- `inline_script_hashes.cr` — только вместе с CSP; если CSP не делаем — notes.
- `set_platform.cr` — функционально покрыт helpers → notes (не создавать).

## Фаза F — views (58 missing; по категориям разведки)

- **(a) переименование/вынос из влитого инлайна — безопасно** (~22):
  `searches/show→index` (+экшен/роут), `autocompletable/users/show→index`
  (+экшен), `messages/by_bots/bot_{index,show}→{index,show}` (+экшены),
  `messages/boosts/by_bots/bot_create→{create|show}` — сверить с роутами
  оракула; вынос партиалов `_bot`, `_form`, `_prompt_item`, `_ban_button`,
  `_transfer`, `_membership`, `_next_page_container`, `_help_contact`,
  `_invite`, `_user` (closeds/opens), `_direct_placeholder`, `_shared`,
  `users/new` (joins→users#new: см. notes — осознанное отклонение, оставить
  и зафиксировать) и т.д.
- **(b) инлайн-HTML в ChatLayout — вынос в .erb файл возможен только там, где
  шаблон компилируется в контексте контроллера** (implicit-scan без
  ignore-list); где нужны ChatERB-локалы — остаётся `_`-префикс (документиро-
  ванный трюк) → в notes как известное отклонение. Кандидаты на вынос:
  `messages/index.html.erb`, `messages/create/destroy.turbo_stream.erb`,
  `rooms/refreshes/show.turbo_stream.erb`, `messages/room_not_found.html.erb`.
- **(c) генерация кодом** (pwa/service_worker, avatars/show.svg и др.) —
  notes-таблица «oracle-путь → генератор».
- **(d) мейлер, accounts/users-пагинация, incompatible_browser** —
  функциональность отсутствует: пагинацию/`incompatible_browser` делаем в
  фазе E+F, мейлер — notes.

## Фаза G — инфраструктура + soft_check + notes

- `twinshot.yml`: добавить в soft_check Rails-инфра без Crystal-аналога:
  `bin/*`, `config/{boot,ci,environment,puma*,redis,resque-pool,brakeman,
  bundler-audit}.code.txt`, `config/environments/*`, `config/locales/*`,
  `config/initializers/*` (после разбора: существующие эквиваленты переносим
  в `config/initializers/*.cr` — assets; остальные soft_check), `hooks/*`,
  `lib/*`, `script/*`, `bench/*`, `public/502.code.txt`, `log/*`, `tmp/*`
  (+исправить опечатку `taks/*`), `db/migrate/*` уже есть.
- `public/robots.txt` — переносим (1 строка).
- `notes/style-parity.md`: дополнить маппингами «oracle-путь → текущее место»
  для (b)/(c)-вьюх, RecordCache/Purchaser/MessagesCount/allow_browser/CSP,
  `users#new` в JoinsController и пр.

## Критерий готовности

- missing in current: 375 → ~150 (остальное — soft_check Rails-инфра и
  зафиксированные deviations).
- `rake build:crails` зелёный после каждой фазы.
- `twinshot review default` — без регрессий (128/129 базлайн).

## Результат (2026-10-23)

Создано/перенесено ~95 файлов: helpers (9 renames + emoji/translations),
models (application_record + abstract-репарентинг, разбор misc.cr и
opengraph.cr, 20 concern-файлов, Push::Subscription, ResponseCache,
Sound, ApplicationPlatform), channels (RoomChannel база, ReadRooms,
TypingNotifications, RoomStreamsAreAuthorized-reopen, guarded_stream?),
jobs (ApplicationJob + 5 джобов, MessagePusher, destroy_later вместо
bulk DELETE в RoomsController#destroy + broadcast_remove_room),
controllers/concerns (raw_request_body, version_headers, room_scoped,
authentication/session_lookup, active_storage_authentication,
allow_browser + sessions/incompatible_browser), views (pwa/*,
searches/autocompletable/by_bots ренеймы экшенов под оракул,
messages/{index,create,destroy}, rooms/refreshes/show как реальные
шаблоны через __render_view). Новая функциональность, которой не было:
typing-notifications сервер, read-rooms подписка, unread-fanout
(Message::BroadcastUnreadRoomJob), X-Version/X-Rev, allow_browser-гейт,
двухфазное удаление комнаты (без orphan-стримов boosts/rich_texts/FTS).

`twinshot review code`: 197 pass / 354 warn / 283 fail, missing 301
(было 375). Дальнейшее снижение требует либо патча action_pack_cr
(ignore-list для implicit-scan под `_`-шаблоны), либо выноса рендера
сообщений из ChatLayout в ERB — отдельные большие планы.
