<p align="center">
  <img src="crails-icon.svg" width="72" alt="CRails">
</p>

<h1 align="center">ONCE Campfire on CRails</h1>

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
| Revision   | [`90b3300`](https://github.com/basecamp/once-campfire/commit/90b3300) | [`bb70a7d`](https://github.com/basecamp/once-campfire-express/commit/bb70a7d) | [`c4ab53d`](https://github.com/basecamp/once-campfire-go/commit/c4ab53d) | [`6dae2fd`](https://github.com/basecamp/once-campfire-rust/commit/6dae2fd) | [`873a51f`](https://github.com/basecamp/once-campfire-c/commit/873a51f) | [`58964cf`](https://github.com/basecamp/once-campfire-elixir/commit/58964cf) | [`c096b40`](https://github.com/OrelSokolov/once-campfire-crails/commit/c096b40) |

Revisions pin the exact code each column was measured against: Express, Go,
Rust, C and Elixir are upstream checkouts from 2026-10-09 (the same pins as
the harness baselines). The Rails column is the vanilla reference `90b3300`
(no response cache; the later upstream-optimized Rails with a
whole-response cache reaches ~4.1k RPS on the official stand and is a
different revision). CRails `c096b40` is the commit that produced the
numbers above.

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
on every request — no response cache was applied there. Push notification
delivery is a no-op without VAPID keys — the same trade-off as the official
Express implementation (`if (!VAPID_PRIVATE_KEY) return`); the notification
jobs themselves are still created and persisted before the response.

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

## How the other implementations are built

Same dimensions, same machine, revisions pinned in the results table above.

| | Rails | Express | Go | Rust | C | Elixir | **CRails** |
|---|---|---|---|---|---|---|---|
| Transport | Puma | `node:http` + Express 5 | stdlib `net/http` + built-in "Thruster" (h2c, TLS/ACME) | axum/hyper/tokio + own front-server (h2c, TLS/ACME) | custom epoll server (picohttpparser, HTTP/1.1) | Bandit + Plug, behind a Thruster proxy | **ServerX: nginx-model, buffer per connection, offset parser** |
| Processes | Puma workers (3×5 threads) | cluster + `reusePort: true` (`WEB_WORKERS`) | 1 process, goroutine-per-connection | 1 process, tokio threads = CPU | 1 process: 1 loop thread + 4 worker threads, no SO_REUSEPORT | 1 BEAM OS process, no clustering | **3 fork workers + SO_REUSEPORT** |
| Whole-page response cache | none (every response re-rendered) | LRU 64 MB + `data_version` epoch | LRU 64 MB + pinned `data_version` | ≤1 MB/entry + 15 s TTL | 64 MiB + `data_version` epoch | 64 MB FIFO, final gzip bytes | LRU 64 MB + `data_version` epoch |
| Fragment cache | — | LRU 32 MB (`messages/{id}-{updated_at}`) | LRU 32 MB (sidebar frame) | LRU 32 MB, per-message | none (views are C code) | ETS, keyed by `updated_at` | none (page cache covers it) |
| Gzip | Rack::Deflater | spliced gzip (stable segments deflated once) + compression L6 | front gzip L6, precompressed assets | zlib-rs L6 + front zstd L1, `.br`/`.gz` embedded in the binary | gzip representation stored in cache | re-deflated on every response (25% CPU) | lazy gzip in the page cache |
| ETag/304 | yes | weak fast-etag (crc32) | weak `W/"..."` | SHA-256, Rack-style | `W/"sha256(body)"` | `W/"sha256"` over the whole body | SHA1 prefix in the page cache |
| Session on hot path | SQL per request | SQL through an LRU query cache → effectively 0 queries on a hit | SQL per request (JOIN sessions+users, before cache lookup) | SQL per request (`find_by_token` + `find_by_id`) | 2 SQLs before cache lookup | full auth path even on a hit (3–4 SQL + AES decrypt) | **1 PRAGMA per request** (IdentityCache) |
| Prepared statements | — | LRU 512, `IN` via `json_each` | cache 256, `IN` via `json_each` (stable SQL shape) | `prepare_cached` (256) | fixed SQL per connection | LRU 64 per reader (writer re-prepares) | crystal-db cache |
| N+1 | — | none: `IN (json_each(?))` batches | none: LEFT JOIN in messageSelect + `IN json_each`; deliberate N+1 on boosts | none: presenter memoization + fragment cache | none: `IN json_each(?)` | yes: ~200 SQL per room render | none: one `IN (...)` per entity, JOIN for sidebar |
| DB architecture | — | 1 connection + background checkpointer | 1 writer + N ro-readers + a pinned ro connection for `data_version` | 1 writer thread + N reader threads + checkpointer thread | ro pool + 1 writer thread (queue 256) | 1 writer GenServer + reader partitions, every query is a GenServer.call (row copies) | pool per fork worker, WAL |
| Notable extras | — | memoized AES-cookie decrypt | extra `messages(room_id, created_at/updated_at)` indexes at startup | jemalloc, LTO, THP disabled, RLIMIT_NOFILE | static HTML views compiled into the binary | keys cached in `persistent_term` | `-Dwithout_mt` (fork vs MT Crystal runtime) |

The winning combination is the last column's, and no other implementation
has all three pieces at once: multi-process SO_REUSEPORT transport (only
Express clusters too), a whole-page cache (Go/Rust/C/Elixir have one as
well), and a session cache that reduces the hot path to a single
`PRAGMA data_version` — every other implementation pays 2+ SQL per request
for auth before its cache is even consulted.

## Build and run

The full comparison pipeline — download the pinned competitor repos,
build every production image, verify with the official
[once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
harness, then run the formal benchmark — is a single rake task:

```sh
rake deps            # host dependencies (apt/brew, rustup, sqlite3 with FTS5)
rake download        # clone competitor repos at their pinned revisions
rake build           # production docker images (crails builds last)
rake harness         # verifier checkout + crails patch + loadgen + seed DB
rake verify          # preflight: route contracts against every image
rake benchmark       # formal run: 3 rounds, 16 clients → benchmarks/
rake report          # comparison table (routes × apps, medians) from benchmarks/ summaries
rake run             # all of the above, sequentially
```

Granular per-app tasks: `rake download:c`, `rake build:rust`,
`rake benchmark:c,go` — the colon form is preferred, because bash expands
the bracket form (`rake benchmark[crails]`) against the `benchmarks/`
results directory and silently runs nothing; quoted
`rake 'benchmark[crails]'` also works. Knobs: `BENCH_SERVER_CPUS`/`BENCH_CLIENT_CPUS`
(default: auto-detected 2 SMT cores for the server, 4 separate cores for
the load generator), `BENCH_ROUNDS`, `BENCH_DURATION`, `REBUILD=1`,
`DRY_RUN=1` — see the Rakefile header. Raw results are copied to
`benchmarks/<UTC-timestamp>-<apps>/`; the working tree of cloned repos,
the verifier and the seed live in gitignored `bench-workspace/`.

Two environment notes are collected in [REPORT.md](REPORT.md): the exact
build stack is pinned in [environment.md](environment.md), and the digest
assets must be generated before the image build (the rake tasks do this
automatically):

```sh
node ../once-campfire-express/bin/build-assets.js  # → assets/generated/public/assets
cp -r ../once-campfire-express/assets/generated/public/assets/. public/assets/
```

Standalone app image:

```sh
bin/docker-build.sh          # docker build -t once-campfire-crails:app .
docker run --rm -p 3000:3000 \
  -e SECRET_KEY_BASE=... -e HTTP_PORT=3000 once-campfire-crails:app
```

Or locally: `shards install && crystal build src/app.cr -o bin/app --release -Dwithout_mt`.

Requires a seed database (built by the harness's `bin/seed`) mounted at
`/rails/storage/db/production.sqlite3`; environment: `DATABASE_URL`,
`SECRET_KEY_BASE`, `WEB_CONCURRENCY`, `CAMPFIRE_RESPONSE_CACHE_MB` (default 64).
