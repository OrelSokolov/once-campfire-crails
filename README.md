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

## Measurement environment

All CRails, C and Elixir numbers below were measured on this machine:

- **Xiaomi Redmi Book Pro 16 2024** laptop
- **Intel Core Ultra 7 155H** — 6 P-cores + 8 E-cores + 2 LP E-cores
  (16 cores / 22 threads), up to 4.8 GHz; 32 GB RAM
- Linux kernel 7.2.6, Docker (`--network host`)
- Server pinned to `--cpuset-cpus 8-11`: 4 hardware threads of two
  P-cores (SMT pair each, up to 4.5 GHz); load generator pinned to
  cpuset 12-15 (E-cores), so client and server never share cores
- Same seed database, same 3-round × 16-client methodology for every app

As a laptop (shared memory bandwidth, thermals), absolute numbers are
specific to this machine; the Rails/Express/Go/Rust columns are the
harness's recorded baselines taken with an equivalent CPU split
(4 P-core threads for the server, E-core threads for the client).

## Benchmark results

Official harness, median of 3 rounds, 16 concurrent clients, 4 physical cores
(`--cpuset-cpus 8-11`, WEB_CONCURRENCY=3 fork workers), seed database.
Rails/Express/Go/Rust numbers are the recorded baselines of this harness
(`bench/results/600-campfire-baselines.md`, cpuset 0,2,4,6 — also 4 P-cores);
C and Elixir were built from their upstream repositories and measured on this
machine with the identical stand and methodology.

| Route      | [Rails](https://github.com/basecamp/once-campfire) | [Express](https://github.com/basecamp/once-campfire-express) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) | [C](https://github.com/basecamp/once-campfire-c) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [CRails](https://github.com/OrelSokolov/once-campfire-crails) |
|-----------:|------:|--------:|------:|-------:|-------:|-------:|-----------:|
| room_show  |   157 |  19 492 | 26 598 | 52 536 | 57 202 |   3 025 |  **59 670** |
| messages_page | 273 | 35 114 | 28 369 | 47 213 | 56 482 |   3 210 |  **58 500** |
| sidebar    |   360 |  46 383 | 32 843 | 52 574 | 60 164 |   3 323 |  **81 153** |
| search     |   238 |  35 999 | 29 802 | 51 970 | 61 153 |   3 275 |  **76 942** |
| /up        | 2 826 |  47 972 | 59 862 | 81 267 | 122 111 |   5 887 | **148 238** |
| KLOC       |   2.9 |     6.5 |   39.3 |   58.7 |  108.8 |    14.0 |      **2.4** |

**#1 on every measured GET route — including C and Elixir** — with the
smallest code base. KLOC counts non-blank, non-comment lines of the
application's own source in its primary language (Rails: `app/**/*.rb`;
Express: `src/*.js`; Elixir: `lib/**/*.ex`; Go, Rust, C: repository
sources; CRails: `app/`, `src/`, `config/` in Crystal — the CRails
framework itself is published as separate reusable shards, so this is
Campfire-the-product). Remaining routes from the same runs:

| Route        |      C | Elixir | **CRails** |
|--------------|-------:|-------:|-----------:|
| static_css   | 84 703 | 66 870 |  **195 050** |
| avatar       | 35 597 | 55 044 |       2 800 |
| post_message |    690 |    690 |         110 |

`post_message` is a durability-heavy write path (message + rich-text body +
FTS5 index + unread + notification jobs persisted before the response,
audited per write) and is not a throughput route; C and Elixir keep it
under 700 RPS as well. On CRails the avatar path verifies the signed token
(PBKDF2 key derivation), runs two SQL lookups and reads the file from disk
on every request — no response cache was applied there.

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
