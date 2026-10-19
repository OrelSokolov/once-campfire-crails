# SCOPES_REFACTORING — Rails-скоупы 1:1 в CRails

> СТАТУС: выполнен полностью (2026-10-19). Шард опубликован как
> `active_record_cr v0.1.9` (commit 4acd7de, тег v0.1.9), проект переведён
> на `~> 0.1.9` (shard.yml + shards update), повторная верификация: спеки
> 14/14, сборка приложения и смоук-рендер комнаты — зелёные.

Цель: реализовать в `active_record_cr` формат и семантику скоупов Rails так,
чтобы блок скоупов из `once-campfire/app/models/message.rb:16-23` переносился
в `app/models/message.cr` дословно, плюс макрос `has_rich_text`.

Феазибилити доказана спайками: `tmp/spike_scope.cr` (чейнинг через
`method_missing` + `merge`, compile-time ловля опечаток), `tmp/spike_nested_preload.cr`
(вложенные `**opts`-хэши в preload/includes).

## Текущее состояние

- `scope(name, &block)` — только блочная форма (`scope(:opens) { where(...) }`,
  room.cr/user.cr); на Relation скоупы не цепляются.
- `preload/includes(*names : String | Symbol)` — только плоские имена;
  полиморфные и has_one ассоциации не прелоадятся (relation.cr:411-414).
- `Relation#merge` и `method_missing` отсутствуют.
- Rich text: `Message#rich_text`/`#body` написаны руками (message.cr:10-18).
- Вложение аватара: `User#avatar_blob` руками (user.cr:28), не прелоадится.

## Этап 1 — lib/active_record_cr (локальный шард)

1. **`scope` — формат Rails** (base.cr:277): второй позиционный аргумент
   `ProcLiteral` (`scope :ordered, -> { order(:created_at) }`,
   `->(n) { ... }` — параметры без аннотаций допустимы, proc не компилируется).
   Блочная форма остаётся (обратная совместимость room.cr/user.cr).

2. **`Relation#merge(other : Relation(T))`** (relation.cr): where/args —
   конкатенация (AND), `where_hash` — merge, order — конкатенация,
   includes/eager_load/references — union, limit/offset/select/annotation —
   значение other, если задано; distinct/none — OR.

3. **`Relation#method_missing`** (relation.cr): неизвестный метод форвардится
   как `{{ @type.type_vars.first }}.{{ call.name }}(args)` c `merge`.
   Даёт `Message.where(...).ordered` и цепочки скоупов; опечатка — ошибка
   компиляции («undefined method 'publishedd' for Post.class»).

4. **Вложенные preload/includes** (relation.cr): перегрузки
   `preload(**nested : Symbol | String | NamedTuple)` и смешанная
   `preload(*names, **nested)`. Спека разворачивается в dot-пути
   (`creator: :avatar_attachment` → `"creator.avatar_attachment"`) в
   `@includes_values`.

5. **Рекурсивный прелоад путей** (base.cr): `__preload_path(segs, records)` —
   прелоадит голову через `__preload_assoc`, собирает детей новыми геттерами
   `__loaded_assoc_records` / `__cached_assoc_record` (associations.cr) и
   рекурсивно диспетчеризует на класс ребёнка (`{{ a[3] }}` — статический
   вызов, без virtual-метакласса). Вызывается из `Relation#each` для
   dot-путей.

6. **Новые kinds в `__preload_assoc`**: `has_one_poly` (polymorphic has_one:
   `record_type = ? AND record_id IN (...)`) и `as_one` (active storage
   attachment: то же + `name = ?`; 6-й элемент тупла реестра).

7. **`has_rich_text(name, class_name = "ActionTextRichText")`** (новый
   src/action_text.cr): регистрирует `rich_text_#{name}` как `has_one_poly`;
   генерирует `rich_text_#{name}` (учитывает @assoc_cache от прелоада),
   `#{name}` (String?), `#{name}=` (pending + after_save),
   `with_rich_text_#{name}` / `..._and_embeds` (= includes; embeds-обработка
   триxса не портирована — алиас).

8. **`preloadable_attachment(name, attachment_class = "ActiveStorageAttachment",
   blob_class = "ActiveStorageBlob")`**: регистрирует `#{name}_attachment`
   как `as_one`; генерирует `#{name}_attachment` / `#{name}_blob` и скоуп
   `with_attached_#{name}`. Заменяет ручные impl в user.cr; даёт сегмент
   `avatar_attachment` во вложенных путях.

## Этап 2 — спеки шарда (lib/active_record_cr/spec)

Новый spec-файл: скоупы в формате `->`, цепочка `where().scope1.scope2`
(AND-семантика), параметризованный скоуп с Relation, merge, вложенный preload
(2 уровня: has_many → belongs_to), has_rich_text reader/writer +
with_rich_text, preloadable_attachment. Прогон имеющихся oracle-спеков —
без регрессий.

## Этап 3 — приложение

- `app/models/message.cr`: `has_rich_text :body` вместо ручных
  `rich_text`/`body` (behavior `#body -> String?` сохранён; `indexed_body`
  остаётся); скоупы 1:1 с message.rb:
  - `scope :ordered, -> { order(:created_at) }`
  - `scope :with_creator, -> { preload(creator: :avatar_attachment) }`
  - `scope :with_attachment_details, -> { with_rich_text_body_and_embeds.with_attached_attachment }`
    (variant_records не портированы — без них)
  - `scope :with_boosts, -> { includes(boosts: { booster: :avatar_attachment }) }`
  - `scope :with_presentation, -> { with_creator.with_attachment_details.with_boosts.preload(:room) }`
- `app/models/user.cr`: `preloadable_attachment :avatar` вместо ручного
  `avatar_blob` (та же сигнатура).
- Контроллеры: подключить `with_presentation`/`ordered` там, где референс
  Rails их использует (rooms/messages show), если точка замены очевидна.

## Этап 4 — проверка

- `crystal spec` в lib/active_record_cr (новые спеки + oracle).
- `rake build:crails` — сборка приложения.
- Смоук: рендер комнаты с сообщениями/бустами (`bin/app` + curl, как в
  tmp/*.headers-проверках) — вывод не изменился.

## Этап 5 — публикация (AGENTS.md)

- Патч в `~/myshards/active_record.cr`, bump vX.Y.Z, push (с подтверждением).
- shard.yml проекта: подтянуть версию, `shards install`, повторная сборка+тесты.

## Ограничения (зафиксировано)

- `default_scope` остаётся только для одиночного `where` (не нужен message.rb).
- Прелоад вложений не тянет blobs вторым запросом (как сегодня, lazy Blob.find).
- Вложенность preload по polymorphic-ассоциациям не поддерживается.
