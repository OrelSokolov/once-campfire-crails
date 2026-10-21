# FORMS_SUPPORT — паритет хелперов форм с Rails (actionview 8.1.4)

## Короткий ответ

Хелперы форм в crails **не отсутствуют** — база уже есть и байто-точна с
actionview 8.1.4 (проверено оракул-спеками `fw_*`/`ff_*`/`ft_*`, 151 пример):

- `ActionView::Helpers::FormHelper` (`lib/action_view_cr/src/helpers/form_helper.cr`):
  `form_with` (url/model/scope), `fields_for` (view-level), `FormBuilder` c
  `text_field, password_field, hidden_field, check_box, radio_button,
  text_area, fields_for` (nested attributes), `label, submit, field_name`.
- `ActionView::Helpers::FormTagHelper` (`.../form_tag_helper.cr`):
  `form_tag` + `*_tag`-поля (text, password, email, search, url, tel, date,
  color, number, range, hidden), `check_box_tag, radio_button_tag,
  text_area_tag, label_tag, submit_tag, button_tag, select_tag,
  options_for_select`.

Реализовано примерно **половина Rails API**. Недостающее реализовать 1:1
**можно**: оракул-процесс уже отлажен (`lib/action_view_cr/oracle/cases.rb`
гоняется против настоящего гема 8.1.4, он установлен в окружении:
`gem "actionview", "= 8.1.4"`), а базовые механики (`__erb_out`,
`tag_options`, `__av_opts_to_h`, FormModel-интерфейс) уже работают.

Важно: README `action_view_cr` сейчас **приукрашивает** — таблица заявляет
`file_field, select, collection_select, ...` как ✅, хотя их в коде нет.
Поправить в рамках работы (фаза 6).

## Чего не хватает (сверено с реальным actionview 8.1.4)

Замеры сделаны скриптами против настоящего гема (см. «Эталоны» ниже).

### FormTagHelper
- `file_field_tag`, `time_field_tag`, `datetime_field_tag`,
  `datetime_local_field_tag`, `month_field_tag`, `week_field_tag`,
  `phone_field_tag` (алиас), `image_submit_tag`.
- `button_tag` **с блоком** — приложение использует
  `button_tag class: ..., type: "submit" do %>...<% end %`.
- `check_box_tag`/`radio_button_tag`: опция `id: nil`, `disabled`,
  порядок атрибутов (opts идут **до** `checked`).
- `submit_tag`: `data: { turbo_submits_with: ... }` — идёт **до**
  дефолтного `data-disable-with`.

### FormOptionsHelper (модуля нет вообще)
- `options_from_collection_for_select`, `grouped_options_for_select`,
  `option_groups_from_collection_for_select`, `collection_select`,
  `grouped_collection_select`, `collection_check_boxes`,
  `collection_radio_buttons`, `weekday_select`.
- `time_zone_select` — отложить: в active_support_cr нет `TimeZone`
  (см. «Открытые вопросы»).

### FormBuilder
- `file_field` — **самое нужное приложению** (`form.file_field :avatar`
  в 7+ вьюх once-campfire). Тянет за собой механику multipart: Rails
  ставит `enctype="multipart/form-data"` на `<form>`, для этого блок
  формы рендерится ДО открывающего тега (capture-first).
- Типизированные поля: `email_field, number_field, url_field, date_field,
  time_field, datetime_field, datetime_local_field, month_field,
  week_field, search_field, telephone_field, color_field, range_field`.
- `check_box`/`radio_button` с позиционным options-хэшем и
  checked/unchecked значениями — приложение использует
  `form.check_box :role, { data: {...}, hidden: true, id: ..., disabled: ... }, "administrator", "member"`.
- `select` (с `include_blank`/`prompt`/`selected`/`disabled`/`multiple`),
  `button`, `label` с блоком, `field_id` (публичный).
- Порядок атрибутов: `hidden_field` с явным `value:` — Rails пишет
  `autocomplete value type name` (у нас `autocomplete type value name`);
  `check_box` с opts — opts до `type`.

### FormHelper (верхний уровень)
- `form_with` **без блока** (self-closing, без `</form>`) — приложение
  использует для delete-форм (`messages/edit.html.erb:57`).
- `form_with model:` **без `url:`** — сейчас `url:` обязателен, у Rails
  URL выводится из модели (polymorphic). Приложение использует
  `form_with model: room`, `form_with model: [ @message, Boost.new ]`.
- `fields` (form_without_form), `form_for` (legacy).

## Эталоны (зафиксированные замеры actionview 8.1.4)

Проверено живым рендером `OracleView` (`protect_against_forgery? false`,
как в существующем оракуле). Ключевые выводы:

```text
file_field + multipart (блок рендерится до <form>):
<form enctype="multipart/form-data" action="/u" accept-charset="UTF-8"
 data-remote="true" method="post">...<input class="input" type="file" name="user[avatar]" /></form>
• enctype стоит ПЕРВЫМ атрибутом; user-opts до type.

check_box с checked/unchecked values:
<input name="user[role]" type="hidden" value="member" autocomplete="off" />
<input class="sw" type="checkbox" value="administrator" name="user[role]" />
• hidden до checkbox; opts до type.

form_with без блока — </form> НЕ ставится:
<form id="df" action="/u/1" accept-charset="UTF-8" data-remote="true"
 method="post"><input ...utf8... /><input ..._method=delete... />

button_tag с блоком:
<button name="button" type="submit" class="btn">Go</button>

check_box_tag с id: nil:
<input type="checkbox" name="user_ids[]" value="5" class="sw" checked="checked" />
• opts до checked; id опускается.

hidden_field с явным value:
<input autocomplete="off" value="7" type="hidden" name="user[id]" />

submit_tag с turbo_submits_with:
<input type="submit" name="commit" value="S" data-turbo-submits-with="..."
 data-disable-with="S" />

select с include_blank:
<select name="user[role]"><option value="" label=" "></option>
<option value="a">a</option>
<option selected="selected" value="m">m</option></select>
• include_blank → <option value="" label=" "></option>; опции склеены \n.

fields_for внутри form_with генерирует id:
<input type="text" value="bar" name="user[settings][foo]" id="user_settings_foo" />

fields "q" (без модели, без value):
<input type="text" name="q[name]" />
• value-атрибут опускается при nil.

collection_select:
<select name="user[room_id]"><option value="1">A</option>
<option selected="selected" value="2">B</option></select>

options_from_collection_for_select:
<option value="1">A</option>
<option selected="selected" value="2">B</option>

f.field_id → "user_name" (санитизированный, даже в form_with)

f.button (дефолт) → <button name="button" type="submit">Update User</button>
```

Подтверждён и существующий базис: `form_with` в 8.1.4 действительно даёт
`data-remote="true"` и **не** генерирует id у полей — текущая реализация
корректна, ничего не ломаем.

## План

### Фаза 0 — оракул-эталоны (первая, всё через byte-exact)
> **Частично сделано** (2026-10-20) — сняты все эталоны фазы 1 (+граничные
> ft-кейсы): 29 новых `ft_*` в `oracle/cases.rb` / `expected.yml`,
> зеркала в `spec/oracle_spec.cr` (180 examples, 0 failures). Эталоны
> фаз 2–4 (`ff_select*`, `fw_*_noblock`, polymorphic) — ещё не снимались.
> Запуск оракула: `env -u GEM_HOME GEM_PATH=$HOME/.rvm/gems/ruby-3.4.5
> PATH=$HOME/.rvm/rubies/ruby-3.4.5/bin:$PATH ruby oracle/cases.rb
> > oracle/expected.yml` (actionview 8.1.4 живёт в gemset 3.4.5).
1. Расширить `lib/action_view_cr/oracle/cases.rb` новыми case id (все
   кейсы из раздела «Эталоны» + граничные: disabled, multiple select,
   prompt, selected массивом, radio с opts, label с блоком и `for`,
   datetime-поля с датой, `fields` с моделью и без, `form_with` без
   блока с method/GET, `image_submit_tag`, `phone_field_tag`).
2. Прогнать `ruby oracle/cases.rb > oracle/expected.yml` против гема
   8.1.4 (установлен), зеркально добавить кейсы в
   `lib/action_view_cr/spec/oracle_spec.cr`.
3. Критерий: expected.yml пополнен, спеки пока красные (TDD-ориентир).

### Фаза 1 — FormTagHelper добор
> **Сделано** (2026-10-20). Опубликовано action_view.cr **v0.1.3**,
> проект подтянул 0.1.3, `rake build:crails` чистый.

Файл: `lib/action_view_cr/src/helpers/form_tag_helper.cr`.
- `file_field_tag`, `*_field_tag` для time/datetime/datetime_local/
  month/week, `phone_field_tag` (alias), `image_submit_tag`.
- `button_tag` с блоком (через `__erb_out`/capture, как `form_tag`).
- `check_box_tag`/`radio_button_tag`: поддержка `id: nil`, `disabled`,
  порядок атрибутов по Rails (opts до `checked`).
- `submit_tag`: `turbo_submits_with` до `data-disable-with`.
- Попутно: вложенные ключи `data:`/`aria:` хэшей теперь дашеризируются
  в `tag_options` (`turbo_submits_with` → `turbo-submits-with`, как
  dasherize в Rails) — поймано оракулом `ft_submit_turbo`.
- Уточнения оракула 8.1.4 (зафиксированы кейсами): `datetime_field_tag`
  рендерит type="datetime-local"; `image_submit_tag` НЕ ставит
  name/alt по умолчанию, src — через image-asset path (префикс
  `/images/` если путь не абсолютный и не URL); в `label_tag` opts
  идут ДО генерируемого `for`; объект Time в value — просто to_s.
Критерий: все новые `ft_*` кейсы зелёные, старые не меняются. ✅

### Фаза 2 — FormOptionsHelper (новый файл)
> **Сделано** (2026-10-20, v0.1.5), кроме time_zone_select (нет
> `ActiveSupport::TimeZone` в active_support_cr — фиксируется как
> «не входит в паритет 1:1», приложение не использует). Отклонение:
> вместо symbol-методов Rails (`:id`, `:name`) коллекции реализуют
> интерфейсы `ActionView::FormOption` (`option_value`/`option_text`)
> и `GroupOption` (`group_label`/`group_options`). Tag-уровневые
> `collection_select_tag`-функции НЕ вводились — их нет в Rails
> (вместо них `select_tag` + `options_from_collection_for_select`,
> как у референса); builder-методы — см. фазу 3 п.4.

Файл: `lib/action_view_cr/src/helpers/form_options_helper.cr`.
- `options_from_collection_for_select`, `grouped_options_for_select`,
  `option_groups_from_collection_for_select`.
- Tag-уровень: `collection_select`-семейство как `*_tag`-функции;
  builder-методы — в фазе 3.
- `collection_check_boxes` / `collection_radio_buttons` (включая скрытый
  `input name="...[]" value="0"`-механизм у check_boxes... по факту
  Rails его не ставит у collection_check_boxes — сверить по кейсу).
- `weekday_select`.
- Подключить модуль в `form_tag_helper.cr`/`form_helper.cr`
  (`include FormOptionsHelper`) и в `action_view_cr.cr`.

### Фаза 3 — FormBuilder добор + multipart
> **Сделано** (2026-10-20, пункты 1–3, 5) — в action_view.cr **v0.1.4**.
> Не делался только п.4 (select/collection_select — см. фазу 2:
> референс-приложение select'ы не использует вовсе, единственные
> `form.*_field` в once-campfire — это `file_field` ×7).

Файл: `lib/action_view_cr/src/helpers/form_helper.cr`.
1. Перестроить `form_with`/`form_tag` на capture-first: сначала блок в
   строку, затем `<form ...>` (+ `enctype` при multipart) + контент +
   `</form>`. Проверить семантику `__erb_out` в erb_cr (блочные хелперы
   уже так работают — переиспользовать механику).
2. `file_field` (ставит multipart-флаг на builder), 13 типизированных
   полей (общий приватный конструктор по образцу `__av_field`, значения
   дат — ISO8601).
3. `check_box`/`radio_button`: позиционная сигнатура
   `(attr, options = {}, checked_value = "1", unchecked_value = "0")`;
   порядок атрибутов по эталонам.
4. `select` c `include_blank`/`prompt`/`selected`/`disabled`/`multiple`;
   `collection_select`/`grouped_collection_select`/
   `collection_check_boxes`/`collection_radio_buttons` (делегируют в
   FormOptionsHelper).
> **Сделано** (2026-10-20, v0.1.5) + `weekday_select` (дни с понедельника,
> значения — имена дней). Уточнения оракула: include_blank →
> `<option value="" label=" ">` + "\n"; prompt добавляется ТОЛЬКО при
> пустом значении модели (`prompt: true` → "Please select"); multiple →
> `name[]` + скрытый `<input name type=hidden value="" autocomplete>`
> ПЕРЕД select; в `<select>` user-opts до name; у чекбокс-коллекций
> скрытый companion в начале, id форсируются (type, value, checked,
> name, id) + `<label for>`. Отклонение: checked-набор чекбоксов —
> именованным аргументом `checked:` (FormValue не содержит массивов).
> Rails-блоки-билдеры (b.label { b.checkbox }) не поддержаны —
> рендер по умолчанию (checkbox + label), приложение не использует.
5. `button`, `label` с блоком и `for`/id-семантикой, публичный
   `field_id`, порядок атрибутов `hidden_field`.
Критерий: все `fw_*`/`ff_*` новые кейсы зелёные; сущ. 151 — зелёные. ✅
(193 examples, 0 failures).

Уточнения оракула 8.1.4 (зафиксированы кейсами fw_typed_*/fw_check_*):
- датовые поля и color_field ставят `value` ДО `type`; прочие
  типизированные — opts, type, value, name, id; id всегда последним;
- Time-значения форматируются ISO: date `%F`, time `%H:%M:%S.%L`
  (с миллисекундами!), datetime/datetime_local `%FT%T` без зоны,
  month `%Y-%m`, week `%G-W%V`; невалидный color → `#000000`;
- checked-логика check_box: Bool-атрибут — по своему значению,
  прочие — `value.to_s == checked_value`;
- label с блоком в form_with — БЕЗ `for`;
- `f.button` без текста требует I18n model_name — порт отклонение:
  текст или блок обязательны.
Отклонение от Rails: позиционный хэш-аргумент `f.check_box :role,
{...}, "administrator", "member"` невозможен в Crystal — значения
именованными аргументами (`checked_value:`/`unchecked_value:`/`hidden:`).

### Фаза 4 — FormHelper верхний уровень
> **4a сделано** (2026-10-20, v0.1.4): `form_with` без блока —
> открывающий тег + hidden-поля, БЕЗ `</form>` (оракул fw_no_block);
> заодно `method:` опция form_with (ранее method выводился только из
> persisted?). **4b-prep сделано** (v0.1.6): конфиг-ручки семантики
> форм Rails — `form_with_generates_remote_forms` /
> `form_with_generates_ids` (FormHelper), `default_enforce_utf8`
> (FormTagHelper) — дефолты гема, приложение ставит load_defaults-8.x
> значения (локальные формы, ids, без utf8); порядок атрибутов
> form_with user-opts → enctype → action → accept-charset → method;
> label с for при ids; nil-value опускается; password без value;
> size из maxlength (оракул fw_local/fw_ids_model/ff_password/
> ff_text_nil). **4b сделано** (2026-10-21): полиморфный `model:` без
> `url:` — оракул fw_poly_* (4 кейса: new → collection-путь,
> persisted → member + _method patch, `[user, post]` → вложенный
> `/users/:id/posts(:id)`, scope всегда от ПОСЛЕДНЕЙ модели — как в
> Rails); FormModel += `form_model_name`; FormHelper.polymorphic_path
> (хук-прок, вайрится railties на boot — action_view не видит route
> set); UrlHelpers.polymorphic_path (action_pack_cr): имена моделей →
> route name (persisted → `room_message_path`, new →
> `room_messages_path`), значения из `to_param`; `model:` принимает
> Array(FormModel) (в Crystal массив разных моделей — с `of
> ActionView::FormModel`). Опубликовано: action_view.cr v0.1.12 +
> v0.2.10-fix action_pack.cr (инференс `&.`-шорткэта в proc-контексте)
> + railties.cr v0.1.14. `fields`/`form_for` — остались несделанными.
- `form_with` без блока: вернуть открывающий тег + hidden-поля, БЕЗ
  `</form>` (по эталону).
- `form_with model:` без `url:`: вычисление action из модели —
  интеграция с URL-хелперами action_pack_cr (см.
  `URL_HELPERS_GENERATOR.md`) + `model_name`/`persisted?` из FormModel;
  массив `model: [ @message, Boost.new ]` → вложенный путь.
- `fields` (билдер без `<form>`), `form_for` (legacy-обёртка).
Критерий: оракул-кейсы + ручной smoke через вьюху приложения.

### Фаза 5 — интеграция в приложение (once-campfire-crails)
> **Начата** (2026-10-20). Сделано:
> - конфиг приложения (config/application.cr): remote_forms=false,
>   generates_ids=true, enforce_utf8=false — семантика load_defaults
>   8.x оракула (локальные формы без data-remote/utf8, ids полей);
> - `sessions/new.html.erb` — форма логина переведена на
>   `form_with url: + form.email_field / form.password_field /
>   form.button` (блок с иконкой): login.png байт-в-байт с оракулом,
>   login/login-error/login-banned.html structure-identical,
>   логин-POST тестами зелёный; мёртвый `SessionsHelpers#email_value`
>   удалён (value теперь через `value:` у email_field).
> - `accounts/edit.html.erb` — частично: две logo-формы
>   (`form_with url:, method: "patch", scope: "account"` + `file_field
>   :logo` с data-action; enctype multipart поднимает file_field сам)
>   и name-форма (`form_with ... scope: "account"` + `text_field :name`
>   c явным `value:` — модели нет — и `form.button` блоком);
>   test_account_settings_page_renders — формы байт-в-байт с оракулом
>   (единственный diff — био-шум сиута). Хвост переведён (2026-10-21,
>   см. блок «accounts/edit хвост закрыт» ниже): settings-форма, join_code,
>   delete-logo button_to с блоком, user-строки.
> - action_view.cr v0.1.7: ручка `method_field_autocomplete`
>   (дефолт on = 8.1.4-гем; приложение ставит false — поведение 8.2
>   `_method`-hidden без autocomplete="off"; не oracle-кейс, обычная
>   спека по байтам артефакта rails-оракула). v0.1.8: нормализация
>   вложенных NamedTuple/Hash опций (`data: {controller: "form"}` из
>   ERB) в `__av_opts_to_h`/`tag_options` — Symbol-ключи и named
>   tuples flattening'ятся как в Rails. v0.1.9: явные `id:`/`for:` в
>   опциях подавляют автогенерацию (skip_default_ids), text_area
>   принимает `value:` (oracle ff_textarea_value), порядок атрибутов
>   opts→name→id.
> - `accounts/bots/new+edit.html.erb` — форма бота переведена
>   (`form_with url:, scope: "user"` / `method: "patch"` + `file_field
>   :avatar`, `text_field :name`, `url_field :webhook_url`); button_to
>   с блоком (delete/key) и submit-кнопка без name оставлены сырыми.
>   bot-new.html байт-в-байт с оракулом.
> - `users/profiles/show.html.erb` — все три формы через новый
>   `profile_form_with` (app/helpers/profiles_helpers.cr — form_with
>   PATCH /users/me/profile, scope user): `file_field :avatar` с
>   явным `id: "file"`, `text_field :name`/`email_field`/
>   `password_field`/`text_area :bio` с явными `value:`; profile.html
>   и profile-edited.html байт-в-байт с оракулом.
> - `messages/boosts/new.html.erb` — форма буста (`form_with url:
>   message_boosts_path, scope: "boost"` + `text_field :content` с
>   `id: nil`, pattern строкой, size из maxlength + `form.button`);
>   форма живёт в turbo-frame и верифицируется DOM-тестами
>   (custom-boost/quick-boost зелёные).
> - `rooms/_form.html.erb` — форма комнаты (`form_with url:
>   "/rooms/#{kind}[/id]", method: patch|post, scope: "room"` +
>   `text_field :name` + `form.button`); room-settings.html
>   байт-в-байт. Для этого erb.cr v0.1.4: template_processor матчит
>   `<% end %>` со стеком конструкций (контрольные блоки, обёртывающие
>   `<%= expr do %>`, больше не парсятся неверно).
> - `rooms/_form.html.erb` — форма комнаты (`form_with url:
>   "/rooms/#{kind}[/id]", method: patch|post, scope: "room"` +
>   `text_field :name` + `form.button`); room-settings.html
>   байт-в-байт. Для этого erb.cr v0.1.4: template_processor матчит
>   `<% end %>` со стеком конструкций (контрольные блоки, обёртывающие
>   `<%= expr do %>`, больше не парсятся неверно).
> - `first_runs/show.html.erb` + `joins/show.html.erb` (2026-10-20):
>   обе signup-формы переведены (`form_with url: first_run_path /
>   "/join/<code>", scope: "user"` + `text_field :name` /
>   `email_field :email_address` / `password_field :password` +
>   `form.button` блоком). Смоук: рендер до/после — только ожидаемые
>   Rails-parity диффы (autofocus/required="…", size="72" из
>   maxlength, name="button", authenticity_token — как у уже
>   переведённого login); POST-флоу обеих форм проверен (first_run:
>   аккаунт+админ+сессия; join: юзер+memberships в opens). Попутно
>   закрыт баг шарда: action_view.cr **v0.1.10** — Bool в `data:` и
>   небулевых атрибутах рендерится "true"/"false" по Rails
>   tag_options (BOOLEAN_ATTRIBUTES → key="key"), oracle-кейсы
>   tag_data_bool/tag_plain_bool_true (219 примеров зелёные).
>   Аватар-upload в этих формах не портирован (нет has_secure_*) —
>   file_field осознанно не добавлялся. Верификация: `rake
>   build:crails` чистый; twinshot review default (полная
>   регенерация обеих сторон) — 127/129, оба оставшихся png-диффа
>   это soft_check-файлы из twinshot.yml (custom-boost, mobile),
>   регресса нет.
> Порядок дальнейшего перевода: accounts/edit хвост (settings-форма
> через fields_for :settings + Settings FormModel, join_code,
> delete-logo button_to с блоком, account_user_row). Остальные
> страницы переведены. По странице за проход, полный twinshot после
> каждой. `ActionController::Base` уже включает
> `ActionView::Helpers` — include в контроллерах не нужен.

> **accounts/edit хвост закрыт** (2026-10-21). Сделано:
> - action_view.cr **v0.1.11** (oracle url_button_block*,
>   fw_check_disabled, ff_hidden_no_ac, fw_check_no_ac):
>   `button_to` с блоком (html-опции идут в `<button type="submit">`,
>   форма class→method→action, method: get без _method);
>   `check_box`: `include_hidden:` (Rails-семантика) вместо старого
>   `hidden:` — `hidden: true` теперь проходит в input как boolean-атрибут,
>   `checked:` — явный override (у порта role — Int, а не enum-строка),
>   `disabled`/`form` срезаются в hidden-companion как в Rails;
>   конфиг `remove_hidden_field_autocomplete` (аналог
>   ActionView::Base.remove_hidden_field_autocomplete, load_defaults 8.2)
>   убирает autocomplete="off" с hidden_field/check_box/select/collection
>   companions и utf8-enrollment. Приложение ставит его в true.
> - settings-форма: `form_with url:, method: "put", scope: "account"`
>   + `form.fields_for :settings` + `hidden_field :restrict_…`
>   с явным `value:` — Settings FormModel не понадобился (значение
>   явное, как в шаблоне референса); свитч — сырой `<input>` (tag.input
>   в шаблоне референса тоже сырой вывод атрибутов).
> - delete-logo и join_code — `button_to … do` блоки.
> - user-строки: хелпер `account_user_row` удалён, вместо него партиал
>   `app/views/accounts/users/_user.html.erb` (порт
>   accounts/users/_user.html.erb референса): `form_with url:
>   "/account/users/<id>", method: "patch", scope: "user"` +
>   `check_box :role` (checked_value/unchecked_value administrator/member,
>   `hidden: true`, `disabled:` у себя), `button_to … method: "delete"`
>   с turbo_confirm, `link_to … target: "_top"` «My settings»;
>   аватар — `ChatLayout.avatar_link` в `ERB::SafeString`.
>   Нюанс erb_cr (= Erubi): перевод строки сразу после `<% end %>`
>   съедается — пустые строки в шаблоне расставлены как в ERB
>   референса, чтобы сохранить переносы вывода (`</form>\n<form…`).
> - Попутно закрыт пре-существующий (не от этого прохода; HEAD тоже
>   эмитил) расстрой паритета: порт вставлял `authenticity_token` в
>   формы (10 HTML-диффов в twinshot), оракул (rails-main, lazy-сессии:
>   protect_against_forgery? в контексте рендера false) — никогда.
>   Фикс: `ApplicationController#__csrf_token_field → ""` (мета-токен
>   csrf_meta_tags и header_only-верификация по Sec-Fetch-Site не
>   тронуты — проверено на живом оракуле: /session/new и /account/edit
>   без токена и анонимно, и залогиненным).
>
> Верификация: спеки шарда 225 зелёных; сырой /account/edit порта
> сверен с живым rails-оракулом через harness-нормализацию — секция
> settings+users совпадает (диффы только браузерной сериализации);
> `rake build:crails` чистый; **twinshot review default — 127/129**
> (2 оставшихся — soft_check PNG mobile/custom-boost, как до прохода).
1. App-хелперы из Rails-исходника: `profile_form_with`,
   `auto_submit_form_with` (once-campfire/app/helpers) — положить в
   `app/helpers/` crails-порта (НЕ в контроллеры — по AGENTS.md).
2. `@account.settings` для `fields_for :settings` — Settings-объект
   должен реализовывать `FormModel` (`form_scope`, `form_attributes`,
   `form_persisted?`).
3. Перевод вьюх с сырого `<form action=...>` на хелперы — вьюхи
   once-campfire-crails сейчас пишут формы руками. Делать постранично,
   сверяя вывод twinshot-дифом с Rails-оракулом (порядок: sessions/new,
   first_runs/show, users/new+profiles, accounts/edit, accounts/bots,
   rooms/*, messages/boosts). Опционально по объёму — паритет вывода
   важнее скорости перевода.

### Фаза 6 — публикация (по AGENTS.md, после каждой фазы или пакетом)
1. Всё пилится в локальном шарде `lib/action_view_cr`, спеки зелёные.
2. Патч в `~/myshards/action_view.cr`, bump version `vX.Y.Z`, пуш тега.
3. Подтянуть версию в корневом `shard.yml`, `shards update action_view_cr`.
4. `rake build:crails` — сборка без ошибок.
5. Прогнать `twinshot review default`.
6. Обновить README `action_view_cr` (таблица сейчас врёт про
   file_field/select) и PLAN.md; commit + push.
7. Выполненные планы переносить в `plans/completed/` (AGENTS.md).

## Открытые вопросы / риски

- **time_zone_select**: требует `ActiveSupport::TimeZone` и tz-данные —
  в active_support_cr этого нет. Либо тащить зону-список статикой,
  либо явно зафиксировать «не входит в паритет 1:1» (рекомендую второе;
  once-campfire его не использует).
- **capture-first для multipart**: меняет порядок эмиссии у form_with/
  form_tag — риск регресса байто-точности существующих 151 кейсов;
  митигируется фазой 0 (эталоны снимаются до изменений).
- **I18n у `f.button`/`label`** («Update User»): в crails I18n может не
  быть — дефолты захардкодить по `%{model}`-шаблонам, как в
  actionview, либо завести на существующий механизм переводов
  (свериться с translation_button в приложении).
- **`model:` без `url:`** зависит от зрелости URL-хелперов
  (polymorphic-массивы) — если генератор их не умеет, фаза 4
  разбивается на 4a (без polymorphic) и 4b (после доработки
  action_pack_cr).

## Порядок и оценки

| Фаза | Объём | Зависимости |
|------|-------|-------------|
| 0. Оракул-эталоны | ~40 кейсов | — |
| 1. FormTagHelper | малый | 0 |
| 2. FormOptionsHelper | средний | 0 |
| 3. FormBuilder + multipart | большой | 0, 2 |
| 4. form_with url из модели | средний/большой | 3, URL-хелперы |
| 5. Интеграция в приложение | средний | 1–4 |
| 6. Публикация/README/тwinshot | малый | после каждой фазы |

Минимально полезный срез для приложения: фазы 0 → 1 → 3 (пункты 1–3, 5)
→ `file_field`, блочный `button_tag`, `check_box` с values, `form_with`
без блока — они закрывают все текущие формы once-campfire, кроме
`model:` без `url:`.

> **Статус среза** (2026-10-21): ГОТОВ И ПЕРЕВЫПОЛНЕН — фаза 0 (частично:
> эталоны фаз 1/3/4a/2/3.4), фаза 1 (v0.1.3), фаза 3 п.1–3,5 + фаза 4a
> (v0.1.4), фаза 2 + фаза 3 п.4 (v0.1.5, кроме time_zone_select);
> фаза 5 хвост accounts/edit закрыт (v0.1.11: блочный button_to,
> check_box include_hidden/checked, remove_hidden_field_autocomplete;
> + фикс embedded authenticity_token в ApplicationController);
> фаза 4b закрыта (2026-10-21: polymorphic `model:` без `url:` —
> action_view.cr v0.1.12 + action_pack.cr v0.2.10 + railties.cr
> v0.1.14, оракул fw_poly_*, smoke через boot приложения
> tmp/poly_form_smoke.cr). Осталось: фаза 0 хвост (эталоны
> fields/form_for), `fields`/`form_for`. Опубликованные версии:
> action_view.cr v0.1.3–v0.1.12 (проект на 0.1.12; 229 oracle-кейсов).
> twinshot review default — 128/129 (1 soft_check PNG
> custom-boost.png; до прохода было 127/129 с двумя). Переведённые страницы: sessions/new,
> users/profiles, accounts/edit (полностью),
> accounts/bots (new+edit), rooms/_form, messages/boosts/new,
> first_runs/show, joins/show.
