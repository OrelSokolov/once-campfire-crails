# ATTR_READER — макросы attr_* в отдельный шард + перевод getter → attr_reader

> СТАТУС: выполнен 2026-10-19. Все 6 этапов закрыты: шард attr_reader_cr v0.1.0
> опубликован; active_support_cr v0.1.6/v0.1.7 (реэкспорт); 56 объявлений в
> app/+src/ переведены; 11 шардов — action_cable v0.1.3, action_view v0.1.2,
> active_job v0.1.1, active_record v0.1.10, active_storage v0.1.2, erb v0.1.3,
> importmap v0.1.1, action_pack v0.2.5, railties v0.1.12, propshaft v0.1.2;
> верификация: сборка, смоук (главная/логин/комната), docker-образ,
> twinshot review default 128/129 (единственный диф — soft_check).

Цель, два этапа общей работы:

1. **Вынос функциональности** `attr_reader` / `attr_writer` / `attr_accessor`
   из `active_support_cr` в отдельный микрошард `attr_reader_cr`
   (репо <https://github.com/OrelSokolov/attr_reader.cr.git>), чтобы у шардов,
   которым нужен Rails-стиль, не было тяжёлых/круговых зависимостей.
2. **Перевод всех `getter`/`setter`/`property`** в проекте на макросы
   `attr_reader`/`attr_writer`/`attr_accessor` — единый Rails-стиль.

## Мотивация: почему отдельный шард

Сейчас макросы определены в `lib/active_support_cr/src/attr_aliases.cr`
(macro на `Object`, делегирует к stdlib `getter`/`setter`/`property`).
Проблемы:

- `active_support_cr` тянет зависимости `pg` + `redis`. Любой низкоуровневый
  шард (`erb_cr`, `icr`, `db`, …), желающий Rails-стиль, обязан зависеть от
  `active_support_cr` и получает транзитивно `pg`/`redis`.
- Риск круговых зависимостей: `action_view_cr`/`action_pack_cr`/`erb_cr`
  зависят на `active_support_cr`; если `active_support_cr` когда-нибудь
  захочет зависеть от `erb_cr` (или наоборот, низлежащий шард — от него),
  получится цикл.
- Микрошард с **нулевыми зависимостями** решает обе проблемы: его можно
  подключить в любой шард иерархии.

## Текущее состояние

- Реализация: `lib/active_support_cr/src/attr_aliases.cr` (44 строки),
  require из `active_support_cr.cr:2`. Спека:
  `lib/active_support_cr/spec/attr_aliases_spec.cr`.
- Поддерживаются: Ruby-символы (`attr_reader :foo`), голые имена,
  типизированные объявления с дефолтами (`attr_accessor name : String = "x"`)
  — проходят насквозь в stdlib-макросы.
- В `~/myshards/` шарда `attr_reader.cr` ещё нет.

Объём перевода (только `src/`, без spec/oracle):

| Где | объявлений | файлов |
|---|---|---|
| `app/` + `src/` проекта | 56 | 18 |
| Свои шарды: railties_cr 87, action_pack_cr 42, active_record_cr 42, propshaft_cr 35, active_job_cr 33, active_support_cr 26, action_cable_cr 13, importmap_cr 9, active_storage_cr 7, action_view_cr 4, erb_cr 1 | ~299 | ~60 |
| Форки сторонних (pg 121, redis 71, db 18, icr 9, rqrcode_cr 15, serverx 24, image_processing_cr 25, marcel_cr 8, bcrypt 4, sqlite3 1) | ~296 | — не трогаем |

## Правила перевода (единый стиль)

- `getter foo` → `attr_reader :foo`
- `setter foo` → `attr_writer :foo`
- `property foo` → `attr_accessor :foo`
- Типизированные/с дефолтами — без двоеточий, проходят насквозь:
  `getter id : Int64` → `attr_reader id : Int64`,
  `property jb_origin : String = "..."` → `attr_accessor jb_origin : String = "..."`
- **НЕ конвертируем** (остаются stdlib-макросами):
  - `getter?` — предикат-форма (47 шт. в lib): у Ruby нет аналога
    `attr_reader?`;
  - `private getter/setter/property` (6 шт.) — `private` не применим
    к кастомному macro-вызову;
  - ленивые блок-формы `getter x { ... }` (0 шт. — не актуально).
- Списки нескольких имён сворачиваем: `getter a, b` → `attr_reader :a, :b`.

## Этап 1 — новый шард attr_reader_cr (локально)

1. Создать `~/myshards/attr_reader.cr/` (git-репо, remote =
   `https://github.com/OrelSokolov/attr_reader.cr.git`):
   - `shard.yml`: `name: attr_reader_cr`, `version: 0.1.0`,
     `crystal: ">= 1.21.0"`, зависимостей нет;
   - `src/attr_reader_cr.cr` — перенести macro-код из
     `active_support_cr/src/attr_aliases.cr` как есть (тот же контракт);
   - `spec/attr_reader_spec.cr` — перенести
     `active_support_cr/spec/attr_aliases_spec.cr`;
   - README с таблицей Ruby ↔ Crystal ↔ attr_*.
2. Прогнать `crystal spec` в шарде.

## Этап 2 — публикация attr_reader.cr

1. Коммит + пуш в `origin main`, тег `v0.1.0`.
2. В проекте подключить до выхода в тег — через `shard.override.yml`
   (`branch: main`), после проверки тегом — прямая зависимость
   `attr_reader_cr: github: OrelSokolov/attr_reader.cr, version: ~> 0.1.0`
   в `shard.yml` проекта. `shards install`, убедиться, что макросы
   доступны в проекте.

## Этап 3 — active_support_cr переходит на шард

1. В `lib/active_support_cr` (локальная копия):
   - удалить `src/attr_aliases.cr` и `spec/attr_aliases_spec.cr`;
   - в `active_support_cr.cr` заменить `require "./attr_aliases"` на
     `require "attr_reader_cr"` (реэкспорт: все, кто зависит от
     active_support_cr, продолжают видеть макросы без правок);
   - `shard.yml`: зависимость `attr_reader_cr ~> 0.1.0`,
     bump `0.1.5` → `0.1.6`.
2. `crystal spec` в `lib/active_support_cr`.
3. По workflow AGENTS.md: патч в `~/myshards/active_support.cr`,
   публикация с тегом `v0.1.6`, в проекте `shards update active_support_cr`,
   пин `~> 0.1.6`.
4. Проверка сборки: `rake build:crails`.

## Этап 4 — перевод app/ и src/ проекта

1. 56 объявлений в 18 файлах (больше всего: `app/helpers/chat_layout.cr` —
   17, `app/controllers/searches_controller.cr` — 5,
   `app/helpers/page_cache.cr` — 5, `app/middleware/public_cache.cr` — 4,
   `src/app.cr` — 1) — по правилам перевода выше.
2. Смоук: запуск приложения, проверка главной страницы/комнаты,
   `capybara-tests/run.rb` при наличии затронутых сценариев.

## Этап 5 — перевод фреймворкных шардов (по одному)

Порядок по убыванию объёма; на каждый шард полный цикл AGENTS.md:
локальная правка → `crystal spec` → патч в `~/myshards/<shard>` →
bump version (patch) → публикация с тегом → `shards update` в проекте →

1. `railties_cr` (87) → v0.1.6
2. `action_pack_cr` (42) → v0.1.x+1
3. `active_record_cr` (42) → v0.1.10
4. `propshaft_cr` (35)
5. `active_job_cr` (33)
6. `active_support_cr` (26 — остатки внутри src/)
7. `action_cable_cr` (13)
8. `importmap_cr` (9)
9. `active_storage_cr` (7)
10. `action_view_cr` (4)
11. `erb_cr` (1)

Каждому шарду: добавить зависимость `attr_reader_cr` в `shard.yml`,
`require "attr_reader_cr"` в корневом src-файле, перевести объявления.

Форки сторонних шардов (pg, redis, db, sqlite3, bcrypt, icr, marcel_cr,
image_processing_cr, rqrcode_cr, serverx) **не трогаем** — минимизируем
diff с upstream.

## Этап 6 — верификация и закрытие

1. `crystal spec` по всем затронутым шардам и проекту.
2. `rake build:crails` — без ошибок сборки.
3. Смоук-запуск приложения: главная, комната, логин.
4. Точечный `grep -rE '^\s*(getter|setter|property)\s' app src lib/<свои шарды>/src`
   — пусто (кроме `getter?`/`private`-форм).
5. Обновить README `active_support_cr` (убрать упоминания attr_aliases,
   сослаться на шард attr_reader_cr).
6. Удалить временный override из `shard.override.yml`, если остался.
7. Перенести план в `plans/completed/`.

## Риски

- **Дублирование macro**: пока `active_support_cr` ещё содержит
  `attr_aliases.cr`, а шард уже подключён, определения конфликтуют.
  Поэтому порядок строгий: сначала публикация attr_reader_cr (этапы 1–2),
  потом замена в active_support_cr (этап 3) до его подключения
  в проект.
- **Bump каскадом**: зависимые шарды пинят версии друг друга в `shard.yml`;
  после bump active_support_cr пересобрать `shards.lock` всего проекта
  (`shards update`), иначе локальные и опубликованные версии разъедутся.
- `getter?` и `private getter` остаются stdlib — это осознанное решение,
  зафиксировано в «Правилах перевода».
