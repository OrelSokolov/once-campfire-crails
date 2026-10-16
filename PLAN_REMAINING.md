# Оставшиеся работы — CRails / once-campfire-crails

Дополняет `PLAN.md`: задачи, появившиеся после основного цикла порта.
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
