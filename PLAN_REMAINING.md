# Оставшиеся работы — CRails / once-campfire-crails

Дополняет `PLAN.md`: задачи, появившиеся после основного цикла порта.
Формат тот же — что/зачем/оракул/шаги/критерии готовности.

## 1. `image_processing.cr` — аналог гема `image_processing` (ресайз картинок)

### Почему

В экосистеме Crails нет ни libvips, ни libmagic, ни любого image-шарда
(проверено: `shard.yml` — только фреймворк-шарды + bcrypt/rqrcode/serverx;
`lib/` — то же). Из-за этого не портированы варианты ActiveStorage:

- `Account#logo_variant(:large 512 / :small 192)` — upstream
  `app/models/account.rb:4-7` (`has_one_attached :logo` с вариантами);
  `LogosController` отдаёт оригинал вложения вместо PNG 512/192
  (`app/controllers/logos_controller.cr`);
- representation-путь вложений сообщений подписывает variation
  `{"format":"...","resize_to_limit":[1200,800]}`
  (`app/helpers/chat_layout.cr` → `representation_url`), но отдаёт
  оригинал — ресайза нет (`app/controllers/active_storage_controller.cr:7-8`);
- таблица `active_storage_variant_records` (blob_id, variation_digest) есть
  в `db/schema.yml`, но не используется.

### Оракул (гемы upstream, `once-campfire/Gemfile.lock`)

| Гем | Версия | Роль |
|---|---|---|
| `image_processing` | 1.14.0 | chainable-builder API поверх процессора |
| `ruby-vips` | 2.2.5 | libvips-биндинги (процессор, который ActiveStorage выбирает по умолчанию) |
| `mini_magick` | 5.3.1 | ImageMagick-CLI-процессор (fallback) |
| `marcel` | 2.1.0 | content-type по магическим байтам (ActiveStorage blob) |

Оракул для API-поверхности — исходники и test-suite гема `image_processing`
(janko/image_processing, тег v1.14.0).

### Что делать

Публичный шард `OrelSokolov/image_processing.cr` (монорепо фреймворка,
как остальные шарды), 1 к 1 по API:

1. **`ImageProcessing::Vips`** — процессор на C-bindings libvips
   (`@[Link("vips")]`, как `sqlite3`/`pg` шарды оборачивают C):
   `vips_init`, `vips_image_new_from_file` (+ `VipsForeignLoad` options),
   `vips_thumbnail_image` / `vips_resize` + crop-операции,
   `vips_image_write_to_file` (+ save options); память — glib-object
   ref/unref (`g_object_ref`/`unref`) через `VipsImage*`.
2. **`ImageProcessing::MiniMagick`** — fallback-процессор через CLI
   `convert` (аналог mini_magick), где libvips не установлена.
   Выбор процессора — как ActiveStorage `config.active_storage.variant_processor`.
3. **Общий builder 1:1 с гема**: `.source(path|IO)`, операции
   `.resize_to_limit(w, h)`, `.resize_to_fit`, `.resize_to_fill`,
   `.crop`, `.rotate(deg)`, `.convert(fmt)`, `.loader(**opts)`,
   `.saver(**opts)`, `.apply(...)`, кастомные операции блоком;
   выполнение — `.call` → Tempfile, bang-шорткаты
   (`.resize_to_limit!(w, h, format: "png")`) — «построить и выполнить»,
   как в геме. Семантика `resize_to_limit` — только уменьшение.
4. **`marcel.cr`** (в том же шарде или отдельным) — content-type по
   магическим байтам + расширению; сигнатуры из Marcel 2.1.0.
5. **Спеки**: порт test-suite `image_processing` (minitest → spec) +
   golden-файлы (вход → ожидаемые размеры/формат/прозрачность).

### Интеграция в Campfire (после шарда)

1. `ActiveStorage`-слой порта: обработка variation-JSON через
   `image_processing.cr`, производные файлы в storage
   (`derivatives/<key>/...`), запись `active_storage_variant_records`
   с `variation_digest` — идемпотентность «processed» (повторный запрос
   берёт готовый файл, не пересчитывает).
2. `Account#logo_variant(size)` — как upstream; `LogosController#show`
   отдаёт варианты 512/192 вместо оригинала.
3. `ActiveStorageController#representation` — реальный ресайз
   1200×800 вместо оригинала.
4. `shard.yml`: `image_processing_cr: { github: OrelSokolov/image_processing.cr }`.
5. `Dockerfile`: build-стадия `apk add vips-dev`, runtime `apk add vips`
   (alpine — пакеты есть); пересобрать `shard.lock`.

### Критерии готовности

- [ ] `ImageProcessing::Vips.source(f).resize_to_limit!(512, 512, format: "png")`
      даёт валидный PNG ≤512×512 (проверено `file`/размерами);
- [ ] порт спеков гема зелёный; MiniMagick-процессор проходит тот же сет;
- [ ] `/account/logo` с кастомным логотипом отдаёт PNG 512×512,
      `?size=small` — 192×192 (upstream-контракт);
- [ ] representation-URL картинки-вложения отдаёт ≤1200×800;
- [ ] `marcel.cr` определяет PNG/JPEG/WebP/GIF по байтам (спеки);
- [ ] прогон harness без регресса RPS (vips — нативная библиотека,
      обработка разовая на вариант, не на запрос).

### Отклонения от 1 к 1 (фиксируем заранее)

- Бинарная несовместимость вывода vips между версиями — байты эталона
  Rails не воспроизводимы байт-в-байт; контракт — валидность + размеры
  + формат (harness проверяет контракт ffprobe/файл, не хэши).
- `mini_magick`-процессор — через CLI, не через C (как и в Ruby).
