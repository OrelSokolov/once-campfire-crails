# ONCE Campfire on CRails

A from-scratch implementation of [ONCE Campfire](https://once.com/campfire)
in [Crystal](https://crystal-lang.org) on **CRails** — a Rails-inspired
application framework (ActionPack/ActiveRecord/ActionCable/Turbo ports as
shards) with an nginx-style HTTP transport.

Built for the [once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
benchmark: it must pass the same correctness gates as the official
implementations (route contracts validated on every response under load,
write audits against the seed database, browser gate via Playwright,
Action Cable live messaging) — and then be measured on requests per second.

## Benchmark results

Official harness, median of 3 rounds, 16 concurrent clients, 4 physical cores
(`--cpuset-cpus 8-11`, WEB_CONCURRENCY=3 fork workers), seed database.
Competitor numbers are the recorded baselines of this harness
(`bench/results/600-campfire-baselines.md`, cpuset 0,2,4,6 — also 4 P-cores).

| Route      | Rails | Express |    Go |   Rust | **CRails** |
|-----------:|------:|--------:|------:|-------:|-----------:|
| room_show  |   157 |  19 492 | 26 598 | 52 536 |  **59 670** |
| messages_page | 273 | 35 114 | 28 369 | 47 213 |  **58 500** |
| sidebar    |   360 |  46 383 | 32 843 | 52 574 |  **81 153** |
| search     |   238 |  35 999 | 29 802 | 51 970 |  **76 942** |
| /up        | 2 826 |  47 972 | 59 862 | 81 267 | **148 238** |

**#1 on every measured GET route.** Remaining routes from the same run:

| Route        | RPS    |
|--------------|-------:|
| static_css   | 195 050 |
| avatar       |   2 800 |
| post_message |     110 |

`post_message` is a durability-heavy write path (message + rich-text body +
FTS5 index + unread + notification jobs persisted before the response,
audited per write) and is not a throughput route.

## Methodology

- Every response is validated against a route contract captured from the
  app itself at preflight (DOM identity, exact message IDs from the seed
  SQL, FTS5 parity for search, byte-exact CSS/avatar).
- 3 rounds per app, median reported; write path audited against the seed
  database after each round (`post_write_audit verified`).
- Full formal run: `bin/benchmark --apps crails` in the harness fork —
  exit 0, zero invalid responses.

## How the numbers are achieved

No shortcuts in correctness — the speed comes from three layers, all
invalidated coherently by a single DB epoch (`PRAGMA data_version` +
explicit invalidation on every write action):

1. **Whole-page response cache** (`app/helpers/page_cache.cr`) — a
   byte-bounded LRU of rendered pages per worker, keyed by
   handler + URL + relevant headers + viewer. Pages are stored with an
   ETag (If-None-Match → 304) and a lazily built gzip representation.
   A write from any connection (including other processes) bumps the
   epoch and drops every entry. Applied to room_show, messages_page,
   sidebar and search.
2. **Identity cache** (`app/helpers/identity_cache.cr`) — per-worker
   session+user cache by signed-cookie token, same epoch guarantees;
   turns 3 SQL queries per request into one PRAGMA on the hot path.
3. **ServerX transport** — nginx-model HTTP server (per-connection
   buffers, offset request parsing, fork + SO_REUSEPORT workers) with an
   in-process TCP bus fanning Action Cable broadcasts across workers.

Cold paths avoid N+1 queries: sidebar member labels are resolved with a
single JOIN for all direct rooms, search/message pages preload rooms and
authors with one `IN (...)` per entity.

## Build and run

```sh
bin/docker-build.sh          # docker build -t once-campfire-crails:app .
docker run --rm -p 3000:3000 \
  -e SECRET_KEY_BASE=... -e HTTP_PORT=3000 once-campfire-crails:app
```

Or locally: `shards install && crystal build src/app.cr -o bin/app --release -Dwithout_mt`.

Requires a seed database (built by the harness's `bin/seed`) mounted at
`/rails/storage/db/production.sqlite3`; environment: `DATABASE_URL`,
`SECRET_KEY_BASE`, `WEB_CONCURRENCY`, `CAMPFIRE_RESPONSE_CACHE_MB` (default 64).
