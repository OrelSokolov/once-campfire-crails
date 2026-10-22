# Security

Report vulnerabilities through GitHub private vulnerability reporting
(**Security → Report a vulnerability** on this repository). Please do not
open public issues for suspected vulnerabilities.

This repository is a from-scratch Crystal port of [ONCE Campfire]
(https://once.com/campfire) built on CRails. It aims for security parity
with the Rails original; where the port knowingly deviates, the deviation
is listed in [Known gaps](#known-gaps-vs-the-rails-oracle) below.

## Scope and supported versions

Only the default branch (`main`) is supported. Self-hosted, single-tenant
deployments only — see the trust model below.

## Trust model

Same as Campfire itself: the application is self-hosted and single-tenant,
so the administrator **is** the server operator, with shell, network, and
database access already. Anything requiring the administrator role grants
nothing they do not already have, and is not a vulnerability.

We do want reports of anything a **non-administrator member** (or an
unauthenticated visitor) can reach, and of any credential or network path
held by the Campfire process but not by the operator's own shell.

## Intentional behavior

- **Bot webhook URLs are unrestricted**: an administrator can point one at
  any address, including internal ones, because operators legitimately wire
  bots to their own services.
- **Link unfurling is different** because any member can trigger it by
  pasting a URL, so it validates destinations against private/reserved IP
  ranges (scheme allowlist, per-hop redirect re-validation, size and time
  caps). Known deviation: the port validates DNS but does not pin the
  connection to the validated IP — see Known gaps.
- **Avatars are publicly fetchable** on token paths; tokens are HMAC-signed
  with a dedicated purpose and unguessable.
- **Session transfer links** (Settings → Transfer to another device) are
  multi-use for 4 hours and do not disturb existing sessions — identical to
  the Rails original. Treat the link as a live credential.
- The 20-year session cookie is `HttpOnly` + `SameSite=Lax`; CSRF is
  enforced via `Sec-Fetch-Site` (header-only) verification, as in Rails 8.2.

## Known gaps vs the Rails oracle

The port is under active development. Security-relevant deviations from
the Rails original and their current status (severity is within the
trust model above, member-reachable):

| Gap | Impact | Status |
| --- | --- | --- |
| No HTML sanitizer on message bodies | Stored XSS for any room member | **Fixed** — `HtmlSanitizer` allowlist scrubber in `ChatLayout.text_presentation` (byte-stable pass-through for editor content) |
| `MessagesController#set_room`, `Rooms::RefreshesController`, `Rooms::Directs#edit` resolved rooms without membership scoping | Read/write of any room, incl. DMs, by any member | **Fixed** — membership-scoped lookups |
| `rate_limit` not applied to `sessions#create` | Login brute-force | **Fixed** — `rate_limit to: 10, within: 3.minutes`, spoof-aware `remote_ip` bucketing |
| `Rooms::Opens/Closeds#update` lacks `ensure_can_administer` | Room takeover by a regular member | **Fixed** |
| `force_ssl` / `Secure` cookie flag off; no HSTS | Session token leak over plain HTTP | **Fixed** — `force_ssl`/`assume_ssl` in production (opt out via `DISABLE_SSL`); cookies auto-flagged `Secure` over TLS |
| `CurrentAttributes` process-global, not fiber-isolated | Race conditions in authorization checks | **Fixed** — fiber-local storage (pending shard publish) |
| Unfurl DNS validation without connection pinning | DNS-rebinding SSRF window | **Fixed** — single resolve + connect to validated IP, TLS SNI by hostname |
| `BlockBannedRequests` concern not ported; `remote_ip` trusted `X-Forwarded-For` | Banned users re-register; IP spoofing into `sessions`/`bans` | **Fixed** — concern ported; XFF honored only from trusted proxies |
| Timing-based user enumeration in `User.authenticate` | Account discovery via response timing | **Fixed** — dummy bcrypt digest on unknown email |
| Bot keys 48 bits; SQL equality compare; CSRF skip on any `bot_key` param | Reduced brute-force cost; CSRF-check bypass by param presence | **Fixed** — `alphanumeric(12)` keys, constant-time compare, forgery skip only on successful bot auth |
| No upload size cap on message attachments | Memory/disk DoS | **Fixed** — 100 MB request body cap (413) |
| Avatar blob served with stored content-type inline | Latent stored XSS if SVG uploads appear | **Fixed** — dangerous types forced to `application/octet-stream` + attachment |
| Mention sgids parsed without signature verification | Forged mention chips / push notifications | **Fixed** — sgid verified with the `signed_global_ids` verifier |
| FTS5 operators in search queries unquoted | 500 on queries like `AND` / unbalanced quote | **Fixed** — `match_terms` quoting ported |
| No upload/avatar features yet | — | N/A |

Deferred (framework-level, tracked): none. Live WebSocket connections
are disconnected on logout/ban/deactivation via
`ActionCable::RemoteConnections` (shard `action_cable_cr`), wired in
`User#close_remote_connections` — logout reconnects the client, ban and
deactivation do not.

Shard fixes are published: `active_support.cr` 0.1.10 (fiber-local
`CurrentAttributes`), `action_pack.cr` 0.2.11 (auto-`Secure` cookies on
TLS, spoof-aware rate-limit bucketing); the project pins both in
`shard.lock` and the benchmark image builds with them.

The parity suite (`twinshot review default`) passes 128/129 after the
fixes (one PNG warn, pixel-level).

## Deployment hardening checklist

- Terminate TLS in front of the app (the port does not redirect or set
  HSTS by default) and strip `X-Forwarded-For` at the proxy — the app
  trusts it as-is.
- Set `SECRET_KEY_BASE` (production refuses to boot without it) and
  `VAPID_PRIVATE_KEY` (Web Push is skipped if absent).
- Keep `/join/:code` codes private: every member can see the join link,
  as in the original.
- Run the built binary as an unprivileged user; uploaded blobs live on
  local disk under `storage/`.
