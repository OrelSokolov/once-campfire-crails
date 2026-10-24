# План: выравнивание стиля кода с Rails-оракула (группа `code`)

> **Статус (2026-10-24):** План выполнен в пределах переносимого на
> Crystal. Фазы 1–4 — полностью (миграции, контроллеры, concerns, доменные
> методы моделей + callbacks/enum 1:1). Фаза 5 — выполнена частями:
> предикаты (5.5), fresh_account_logo_path (5.4), раскладка атрибутов (5.3),
> render layout: do (5.7, через compile_layout erb_cr); 5.1 icon→image_tag
> и 5.2 form_with model: — непереносимы для byte-parity (см.
> notes/style-parity.md), 5.6 boosts_dom → render — нет view-слойного
> render в порте. Фаза 6 — роуты 1:1, комментарии ужаты. Фаза 7: 7.1
> Migration[] — оказался за пределами парсера Crystal (см. notes), 7.2
> render layout — сделано, 7.3 has_many do — компромисс
> Membership.grant_to. Хвост find-bang закрыт через reachable_messages
> скоуп (2026-10-24). Дефолт-парити: twinshot review default 128/129
> (единственный фейл — известный пиксельный шум custom-boost.png).

> **Статус (2026-10-22, вечер):** Фазы 1–3 выполнены (миграции, rooms/messages/
> by_bots/boosts/opens/closeds контроллеры, ApplicationController →
> concerns, User#administrator?/#can_administer?). Фаза 5 — исследована,
> замены `icon→image_tag` и `form_with model:` небезопасны для
> byte-parity (см. `notes/style-parity.md`). Фазы 4 (Room-доменные
> методы), 5–7 — не начаты. Доп. выравнивание (2026-10-22): `redirect_to
> *_url` вместо `*_path` (15+ файлов, `*_url`-хелперы шарда),
> `params.require(:sym).permit(:sym)` вместо строк, ренейм
> `qr_codes→qr_code`, `Rooms::Involvements/RefreshesController` вынесены
> из RoomsController (+ роуты `scope module:` как в оракуле,
> `searches`/`user_profile`/`user_push_subscriptions` получили имена).
> Попутно восстановлен случайно удалённый в фазе 3 оверрайд
> `__csrf_token_field → ""` (a8cfcf4) — формы снова без embedded
> authenticity_token, как в оракуле. `twinshot review default` —
> 128/129 (1 warn, известный soft_check png); `review code` — 196 pass /
> 409 fail (структурные missing сократились: involvements/refreshes/
> qr_code теперь существуют, отличия только построчные).

Базлайн `twinshot review code` (2026-10-22): **852 файла, 194 passed / 248 warn / 410 fail**.
Цель — сократить fail за счёт стилевых расхождений, устранимых на Crystal.
Источник расхождений — диффы `twinshot-report/code/` (`code-artifacts/oracle` vs `current`).

Приоритет — от дешёвого к дорогому. После каждой фазы:
`bundle exec twinshot review code` + `cd capybara-tests && bundle exec twinshot review default`.

---

## Фаза 1 — миграции и мелочи (макс. файлов за минимум работы)

16 файлов с диффом ≤4 строк; почти все миграции фейлятся на одну и ту же пару строк.

1. **Убрать заголовок `# Ported 1:1 from ~/once-campfire (Rails).`** из всех
   `db/migrate/*.cr` (в оракуле таких шапок нет). Файлы после этого отличаются
   только `Migration[8.1]` → см. Фазу 5.1.
2. `app/channels/heartbeat_channel.cr` — убрать 2 строки комментария над классом
   (в оракуле файл = 2 строки).
3. `app/models/rooms/closed.cr` — свериться с оракулом (дифф 2 строки, комментарии).
4. `app/views/messages/boosts/index.html` — `<%= boosts_dom %>` → вернуть
   `render "messages/boosts/boosts", message: @message` (см. Фазу 3).
5. `FORMS_SUPPORT.md` (extra in current, **fail**) — либо удалить, либо добавить
   `FORMS_SUPPORT.code.txt` в `soft_check` корневого `twinshot.yml` рядом с
   `1to1.code.txt` / `AGENTS.code.txt`.

## Фаза 2 — контроллеры: before_action вместо инлайн-проверок

Повторяющийся паттерн во всех контроллерах: `X.find?(params["id"]...)` +
`unless x ... response.status = :not_found ... end` в теле каждого экшена.
Оракул — `before_action :set_room` + приватный `set_room` с редиректом.
Это же требование — AGENTS.md (инлайн авторизация недопустима).

Файлы по убыванию диффа (каждый — `before_action` + приватные методы +
strong params):

1. `app/controllers/rooms_controller.cr` (дифф 333):
   - `before_action :set_room, only: [:show, :destroy, ...]`;
   - `find_messages` — приватный метод как в оракуле (SQL можно оставить,
     если scopes `with_presentation/page_around/last_page` ещё не в моделях —
     см. Фазу 4; при появлении scopes — перейти на них);
   - ручной разбор `params["room"]` → `room_params` через
     `params.require("room").permit("name")` (strong parameters уже в
     `action_pack_cr/src/strong_parameters.cr`);
   - `selected_user_ids` — оставить приватным, но упростить по образцу оракула.
2. `app/controllers/messages_controller.cr` (317) — аналогично.
3. `app/controllers/messages/by_bots_controller.cr` (270).
4. `app/controllers/messages/boosts_controller.cr` (141),
   `boosts/by_bots_controller.cr` (119).
5. `app/controllers/users/avatars_controller.cr` (137),
   `accounts/logos_controller.cr` (102) — общий паттерн «найти вложение → 404».
6. `app/controllers/rooms/directs_controller.cr` (130),
   `closeds_controller.cr` (92), `opens_controller.cr`.
7. `app/controllers/accounts/bots_controller.cr` (136),
   `accounts/users_controller.cr`, `users/bans_controller.cr` и др.

Попутно (где встречается): `current_user.try(&.role) == 1` /
`@user.not_nil!.role == 1` → методы `User#administrator?` / `#can_administer?`
(добавить в `app/models/user.cr` по образцу оракула; см. Фазу 4.1).

## Фаза 3 — ApplicationController: разнести по concerns

Оракул подключает 9 модулей: `AllowBrowser, Authentication, Authorization,
BlockBannedRequests, SetCurrentRequest, SetPlatform, TrackedRoomVisit,
VersionHeaders, CachedResponses, InlineScriptHashes`. Current — всё инлайн
в одном классе (7719 байт).

1. Создать `app/controllers/concerns/` (модули Crystal, `include` в
   `ApplicationController` в одну строку, как в оракуле):
   - `authentication.cr` — `current_session`, `current_user`,
     `require_authentication`, `start_new_session_for`, `bot_request?`;
   - `authorization.cr` — `require_admin`;
   - `set_current_request.cr` — `set_current_request`;
   - `tracked_room_visit.cr` — `remember_last_room_visited` (сейчас в
     `RoomsController`);
   - `cached_responses.cr` — `cache_page`, `send_page`, `db_epoch`;
   - signed_id-методы (`generate_signed_id`/`verify_signed_id`) — в
     `authentication.cr` или отдельный модуль.
2. Убрать длинные русские комментарии-пояснения, перенося существенные
   контракты в `notes/` (AGENTS.md: «если что-то не получается реализовать —
   добавляй в записки»); короткие 1-строчные комментарии по образцу оракула
   (`# concerns/authentication.rb#authenticated_as: ...`) можно оставить.
3. Проверить, что контроллеры зовут `broadcast_*_to` напрямую (include
   `Turbo::Streams::Broadcasts` остаётся на `ApplicationController`).

## Фаза 4 — модели: вернуть доменную логику

`app/models/room.cr` (дифф 147): оракул содержит методы, у current — голый AR.

1. `User`: добавить `administrator?` / `can_administer?(room = nil)` по образцу
   оракула (заменяет сравнения `role == 1` в контроллерах и вьюхах).
2. `Room`:
   - `has_many :users, through: :memberships` — `through:` поддержан
     (`active_record_cr/src/associations.cr`), добавить;
   - `open?/closed?/direct?` — вернуть по `type` (`direct?` уже есть по
     `name.nil?` — сверить семантику с оракулом, оставить одну версию);
   - `receive(message)` / `unread_memberships(message)` / `push_later(message)` /
     `default_involvement` / `Room.original` / `Room.create_for` — перенести из
     контроллеров/джобов, где они сейчас инлайн;
   - `destroy_later` — сверить с текущим `RoomsController#destroy`
     (там инлайн `Membership.delete_all` + `Message.delete_all`):
     перенести в модель; `Room::DestroyJob` — если джобов нет, честно
     зафиксировать компромисс в `notes/`.
3. Ассоциации: `has_many :messages, dependent: :destroy` — проверить поддержку
   `dependent:` в `active_record_cr` (в current отсутствует).
4. `has_many ... do ... end` (extension: `grant_to`/`revoke_from`/`revise`) —
   Crystal-шард не поддерживает блоки-расширения ассоциаций. Компромисс без
   патча шарда: class-методы `Membership.grant_to(room, users)` и вызов из
   `Room.create_for`. Расхождение зафиксировать в `notes/`.

## Фаза 5 — вьюхи: Rails-хелперы вместо самописных

Всё ниже — **без патчей шардов**, хелперы уже есть:

1. `icon("x.svg")` и сырые `<img>` → `image_tag "x.svg", size: 20,
   aria: {hidden: "true"}` (`action_view_cr/src/helpers/asset_tag_helper.cr`).
   Файлы: `accounts/edit.html`, `users/profiles/show.html`, `sessions/new.html`,
   `messages/edit.html`, `accounts/users/_user.html` и др.
   Если `icon()` после этого нигде не используется — удалить из
   `app/helpers/view_helpers.cr`.
2. `form_with url: "/account.#{@account.not_nil!.id.not_nil!}", scope: "account"`
   → `form_with model: @account`:
   - вариант `model:` поддержан (`form_helper.cr:66`), но требуется настроить
     `FormHelper.polymorphic_path` на уровне приложения (сейчас не настроен —
     grep по app/config пуст). Инициализация в `config/application.cr`:
     прок-резолвер `model → path` (account → `/account.#{id}` и т.п.).
3. Многострочная раскладка атрибутов — вернуть формат оракула
   (`form.file_field :logo, class: "input", accept: "image/*",`
   `      data: { action: "upload-preview#previewImage change->form#submit" }`).
4. `logo_src` → `fresh_account_logo_path` (url-helper, см. Фазу 6);
   `button_to logo_src, method: "delete"` → `button_to fresh_account_logo_path`.
5. `@user.not_nil!.role == 1` во вьюхах → `Current.user.can_administer?`.
6. `boosts_dom` (предвычисленный HTML) → `render` партиала как в оракуле.
7. `rooms/opens/new.html` + `closeds/new.html`: `render layout: "rooms/layouts/new" do`
   — требует патча шарда (Фаза 7.2), до него не трогать.

## Фаза 6 — роуты

1. `config/routes.cr` (дифф 185): сверить порядок и группировку с оракулом;
   вложенные `scope module:` уже используются — держать структуру 1:1
   (`resources :users` внутри `resource :account` и т.д.).
2. Осознанные отличия (один RoomsController на все виды, transfers#create на
   put/patch, searches#show) — уже прокомментированы в файле; не ломать,
   но комментарии ужать до 1–2 строк.
3. Named-хелперы (`fresh_account_logo_path` и др.) для Фазы 5.4 — проверить,
   что генерируются текущим роутером (`url_helper.cr`).

## Фаза 7 — патчи шардов (по протоколу AGENTS.md)

Порядок для каждого: локальный шард → проверка → патч в `~/myshards/` →
публикация bump `vX.Y.Z` → подтянуть версию в проекте → тест →
`rake build:crails` → коммит.

1. **`active_record_cr`: `ActiveRecord::Migration[8.1]`** — class-method
   `def self.[](version)` возвращающий `Migration` (версия игнорируется,
     идентично Rails 8.1-семантике для наших миграций). После этого миграции
   1:1 с оракулом (вместе с Фазой 1.1).
2. **`action_view_cr`: `render layout: "path" do ... end`** в шаблонах —
   layout-партиал с блоком (используется оракулом в `rooms/opens/new.html`,
   `rooms/closeds/new.html`). Крупнее; делать после Фазы 5.
3. (Опционально, дорого) `active_record_cr`: extension-блоки
   `has_many ... do ... end` — только если решим всё-таки дать 1:1 по
   `Room#memberships.grant_to`.

## Не реализуемо на Crystal / фиксируем в `notes/`

- `%i[ show destroy ]`-литералы → в Crystal только `[:show, :destroy]`.
- `Migration[8.1]` до патча Фазы 7.1.
- `render layout: do` до патча Фазы 7.2.
- `has_many ... do` (extension) до/без Фазы 7.3.
- Инфраструктурные диффы (`db/schema`, `Gemfile.lock`, `README`, `Rakefile`,
  `Dockerfile`, CI) — другой стек, вне скоупа.
- Создать/пополнить `notes/style-parity.md` перечнем выше с примерами.

## Критерий готовности

- `twinshot review code`: fail < 410 (ожидаемо ~минус 15–20 миграций, 2 канала,
  5–7 вьюх сразу после Фазы 1; далее контроллеры/вьюхи).
- `twinshot review default` — без регрессий (после любых изменений, AGENTS.md).
- `rake build:crails` зелёный для фаз 1–6; для Фазы 7 — обязательно.
