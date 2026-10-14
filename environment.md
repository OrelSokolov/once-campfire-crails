# Environment — точный стек сборки и запуска

Проверено по файлам проекта (`shard.yml`, `shard.lock`, `Dockerfile`) и фактическим
версиям инструментов на рабочей машине. Дата фиксации: 2026-10-14.

## Хост-машина (эталон)

- **ОС:** Ubuntu 25.10 (Questing Quokka)
- **Ядро:** Linux 7.2.6-070206-generic x86_64
- **Железо:** Intel Core Ultra 7 155H (16C/22T), 32 GB RAM
- **Docker:** используется с `--network host`
- **Коммит проекта:** `3049e34f31f3c71fb2330e60d365528629922f47` (2026-10-14)

## Компилятор и инструменты

| Инструмент  | Точная версия |
|-------------|---------------|
| Crystal     | 1.21.0 `[57cf7da50]` (2026-07-16), LLVM 20.1.8, target x86_64-unknown-linux-gnu |
| Shards      | 0.20.0 `[b2b98ca]` (2025-12-19) |
| SQLite      | 3.46.1 (2024-08-13) |

`shard.yml` требует `crystal >= 1.21.0` — на Crystal ниже 1.21 проект не соберётся.
Проверка: `crystal --version`.

## Зависимости (shard.lock, версии запинены)

- `railties_cr` 0.1.1, `active_record_cr` 0.1.1, `action_cable_cr` 0.1.1,
  `action_pack_cr` 0.1.1, `action_view_cr` 0.1.0, `active_job_cr` 0.1.0,
  `active_support_cr` 0.1.0, `turbo_cr` 0.1.1, `importmap_cr` 0.1.0,
  `icr` 1.3.0 — все `github.com/OrelSokolov/*`
- `serverx` 0.2.1 (HTTP-транспорт)
- `bcrypt` 0.1.0 +git.commit.4004f17 (jgaskins/bcrypt)
- `rqrcode_cr` 0.1.0
- Транзитивные: `db` 0.15.0, `sqlite3` 0.24.0, `pg` 0.31.0, `redis` 0.16.0

Системные библиотеки для сборки: `libsqlite3-dev`, `libyaml-dev`, `zlib-dev`,
`openssl-dev`; для рантайма: `libgc`, `libevent`, `pcre2`, `sqlite-libs`,
`libgcc`, `libstdc++`, `yaml` (в Dockerfile это `apk add` на обоих этапах;
на Ubuntu — аналогично через apt).

## Сборка и запуск

Локально:

```sh
shards install
crystal build src/app.cr -o bin/app --release -Dwithout_mt
```

- Флаг `-Dwithout_mt` обязателен: serverX использует fork-воркеры
  (`WEB_CONCURRENCY`); MT-рантайм Crystal конфликтует с fork.
- Нужна seed-база от harness'а (`bin/seed`), подключаемая через `DATABASE_URL`.

Переменные окружения: `DATABASE_URL`, `SECRET_KEY_BASE`, `WEB_CONCURRENCY`,
`CAMPFIRE_RESPONSE_CACHE_MB` (по умолчанию 64), `CAMPFIRE_JOBS_DB`,
`CAMPFIRE_STORAGE_ROOT`, `CRAILS_ENV`, `CRAILS_TRANSPORT`, `RAILS_LOG_LEVEL`.

Docker (самый надёжный способ воспроизведения):

```sh
bin/docker-build.sh    # FROM crystallang/crystal:1.21-alpine → alpine:3.20
docker run --rm -p 3000:3000 \
  -e SECRET_KEY_BASE=... -e HTTP_PORT=3000 once-campfire-crails:app
```

## Типичные причины ошибок на другой машине (по убыванию вероятности)

1. Crystal не 1.21.x (поставился 1.20 или другой минор — API шардов пиняется под 1.21).
2. Нет `-Dwithout_mt` при локальной сборке — падение на fork-воркерах.
3. Не установлены dev-заголовки `libsqlite3-dev` / `libyaml-dev` / `libevent-dev` /
   `libgc-dev` — ошибка линковки.
4. Нет seed-базы по `DATABASE_URL` или не задан `SECRET_KEY_BASE`.
5. Другая ОС/архитектура — стек проверен на x86_64 Linux; на macOS/ARM не гарантирован.
