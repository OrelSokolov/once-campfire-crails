# once-campfire-crails — образ для бенчмарка (harness: once-campfire-crails:app).
# Все зависимости — публичные git-шарды (shard.yml), контекст = каталог приложения
# (.dockerignore отсекает lib/, базы, артефакты).
FROM crystallang/crystal:1.21-alpine AS build
# vips-dev (+glib-dev): линковка libvips — ActiveStorage.variant_processor = :vips
RUN apk add --no-cache sqlite-dev yaml-dev zlib-dev openssl-dev vips-dev glib-dev
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install
COPY . .
# release: бенчмарк только на release-сборке (PLAN.md, Фаза 3);
# without_mt: fork-воркеры serverX (WEB_CONCURRENCY).
RUN crystal build src/app.cr -o bin/app-release --release -Dwithout_mt

# 3.22 = the Alpine release of the crystal:1.21-alpine build stage: shared
# .so versions (libxml2 et al.) must match, or musl fails on relocating.
FROM alpine:3.22
RUN apk add --no-cache gc libevent pcre2 sqlite-libs libgcc libstdc++ yaml vips glib
WORKDIR /app
COPY --from=build /app/bin/app-release ./bin/app-release
COPY --from=build /app/public ./public
COPY --from=build /app/db/schema.yml ./db/schema.yml

ENV CRAILS_ENV=production \
    CRAILS_TRANSPORT=serverx \
    DATABASE_URL=sqlite3:///rails/storage/db/production.sqlite3 \
    CAMPFIRE_STORAGE_ROOT=/rails/storage/files \
    CAMPFIRE_JOBS_DB=/rails/storage/db/jobs.sqlite3 \
    RAILS_LOG_LEVEL=warn

EXPOSE 3000
CMD ["./bin/app-release", "serve"]
