# План: Ruby-style bang-методы вместо `not_nil!`

> **Статус:** Выполнено (2026-10-26). active_record_cr v0.1.22 (Base#id! +
> авторегенерация `<attr>!` в ar_codegen) и active_support_cr v0.1.13
> (CurrentAttributes bang + фикс reset) опубликованы и подтянуты в проект.
> Миграция: 244 замены в 73 файлах (app/config/src, .cr/.erb/.jbuilder).
> current_user! добавлен в concerns/authentication и ApplicationCable.
> Смоук: script/bang_smoke.cr (зелёный). `rake build:crails` — ок.
> twinshot review default — 128/129 (единственный фейл — известный
> пиксельный шум custom-boost.png). Остатки `not_nil!` — сознательные:
> regex-код, `@ivar.not_nil!` во вьюхах, ассоциации. Попутно найден и
> починен баг CurrentAttributes#reset (ключ собирался с кавычками).

## Контекст

В коде 374 вызова `not_nil!` (81 файл). Шум создают три повторяющихся паттерна:

| Паттерн | Кол-во | Замена |
|---|---|---|
| `.id.not_nil!` | 153 | `.id!` |
| `<fk>.not_nil!` (room_id, creator_id, ...) | ~100 | `<fk>!` |
| `current_user.not_nil!` / `Current.user.not_nil!` | ~20 | `current_user!` / `Current.user!` |

Идиома — bang-суффикс в духе Ruby («raise вместо nil»). Генерация
автоматическая, без макросов в моделях: геттеры колонок и так эмитятся
макросом `ar_codegen` (base.cr) из `db/schema.yml`, `id` объявлен отдельно
(`attr_accessor id : Int64?`, base.cr:446), атрибуты `Current` — макросом
`attribute` (active_support_cr/current_attributes.cr).

## Фаза 0 — локальные шарды

1. **active_record_cr `src/base.cr`**
   - Рядом с `attr_accessor id : Int64?` (446) добавить:
     ```crystal
     def id! : Int64
       @id || raise(NilAssertionError.new("#{self.class.name}#id is nil (unsaved record?)"))
     end
     ```
   - В `ar_codegen` (541) в цикле по колонкам — эмит bang-геттера после
     `?`-предиката (~639), только для `kw_ok`-колонок (c[3]): имя `until!` —
     валидный идентификатор, но тело вызывает reader по keyword-имени:
     ```crystal
     {% if c[3] %}
       def {{c[0].id}}!
         value = {{c[0].id}}
         value || raise(NilAssertionError.new("#{self.class.name}#{{c[0]}} is nil"))
       end
     {% end %}
     ```
     Bang вызывает **reader, а не ivar** — корректно для enum (String-reader),
     serialize, store. Без аннотации возвращаемого типа: вывод типов сам даст
     не-nil тип (для enum — String).
2. **active_support_cr `src/current_attributes.cr`** — в `macro attribute`
   рядом с getter/setter добавить:
   ```crystal
   def self.{{name.id}}!
     {{name.id}}.not_nil!
   end
   ```
   Даёт `Current.user!`, `Current.session!` на библиотечном уровне.
3. Проверка: сборка приложения + точечный смоук (`id!` на сохранённой записи,
   raise на unsaved, `Current.user!` raise без пользователя).

## Фаза 1 — приложение (app-level имена)

1. `app/controllers/concerns/authentication.cr`:
   `def current_user! : User` → `Current.user!`.
2. `app/channels/application_cable/channel.cr`: `current_user!` для каналов
   (там свой `current_user : User?`).

## Фаза 2 — миграция вызовов

1. Механика: список колонок из `db/schema.yml` → sed-замены
   `.{col}.not_nil!` → `.{col}!` по `app/ config/ src/`, затем вручную:
   `current_user.not_nil!` → `current_user!`, `Current.user.not_nil!` →
   `Current.user!`, `&.id.not_nil!` → `&.id!` (покрывается тем же sed).
2. **Не трогать** (nil легитимен, `not_nil!` честен): regex-код —
   `match[1].not_nil!`, `match.begin.not_nil!`,
   `char_index_to_byte_index(...).not_nil!` в `html_sanitizer.cr`,
   `chat_layout.cr`; ассоциации (`self.account.not_nil!` в joins_helpers) —
   bang для ассоциаций вне скоупа.
3. Контроль: `grep -rn "not_nil!" app config src` — остатки только
   regex-код и ассоциации; сборка зелёная.

## Фаза 3 — публикация шардов (по AGENTS.md)

1. Перенос патчей в `~/myshards/active_record.cr` (bump 0.1.21 → 0.1.22) и
   `~/myshards/active_support.cr` (0.1.11 → 0.1.12).
2. Опубликовать, подтянуть версии в проектном `shard.yml`, `shards update`.
3. `rake build:crails` — проверка сборки.

## Фаза 4 — проверка и закрытие

1. Смоуки: `script/model_smoke.cr` + свежий смоук на bang-методы.
2. `cd capybara-tests && bundle exec twinshot review default` (AGENTS.md).
3. Перенести план в `plans/completed/`.
