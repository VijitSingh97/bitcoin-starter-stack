# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.18.1] - 2026-07-13

### Changed

- **Watch-only balances now align in two columns** — labels left-justified,
  balances right-justified on the same line (the total too), in a fixed-width
  block so the columns line up cleanly on desktop and mobile. Long labels
  truncate with an ellipsis instead of breaking the layout.

## [1.18.0] - 2026-07-13

### Added

- **`blockfilterindex` option to speed up watch-only rescans.** Set
  `"blockfilterindex": true` (full node only) and Bitcoin Core builds a compact
  block-filter index once; then every wallet rescan — current and future — uses
  it to skip non-matching blocks, turning a multi-hour scan into minutes. A
  shared cache, ~a few GB of disk plus a one-time background build. `configure.sh`
  rejects it on a pruned node (bitcoind can't run both). See
  [docs/watch-only.md](docs/watch-only.md#speeding-up-the-first-scan).

## [1.17.0] - 2026-07-13

### Added

- **Watch-only balance history.** Each wallet's balance is now sampled hourly and
  persisted to the `dashboard_state` volume, so the trend survives restarts (the
  fee sparkline, by contrast, is in-memory and resets). A small gold sparkline of
  the history shows next to each balance above the tower. It holds only balance
  numbers + timestamps — never keys — and never leaves the box.
- **Birthday hint in the add form** — a note that setting a wallet's birthday
  skips years of rescanning.

## [1.16.0] - 2026-07-13

### Changed

- **Watch-only balances now show in gold above the tower.** Each wallet's
  balance — and a total once you have more than one — renders in the gold accent
  font above the block tower (at the top of the column on mobile). The card below
  becomes the manager.

### Added

- **Click a wallet's key to expand it.** Each row shows the key/address as
  first-4…last-4 next to the label; click to reveal the full string, click again
  to collapse.
- **Mobile: scroll past the cards to see the tower on its own.** Extra scroll
  room below the cards lets the full block tower fill the screen.

## [1.15.1] - 2026-07-12

### Fixed

- **The watch-only add-form hints no longer get clipped.** The label and key
  inputs are full width now (the date field shares a row with Add), so long
  placeholders like "xpub / zpub / address / descriptor" are fully visible.
- **The dashboard picks up new CSS/JS immediately after an upgrade.** Static
  assets are revalidated each load (cheap 304s) rather than heuristically
  cached, so a deploy's changes show without a hard refresh.

### Added

- **End-to-end coverage for watch-only wallets.** The e2e provisions a wallet of
  each supported key type against the real node — an xpub, a zpub, Satoshi's
  genesis address, and his genesis public key (both resolving to
  1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa) — and CI covers the same types with mock
  data.

## [1.15.0] - 2026-07-12

### Added

- **Watch a single address.** The watch-only key field now accepts a plain
  address (`bc1…`, `1…`, `3…`), not just an `xpub`/descriptor — handy for a
  specific receive address, a donation address, or a paper wallet. It's wrapped
  into an `addr()` descriptor for you.

### Fixed

- **Un-ranged descriptors (a single address or fixed key) failed to import.** The
  import always sent a `range`, which Bitcoin Core rejects on a non-ranged
  descriptor (`"Range should not be specified for an un-ranged descriptor"`), so
  the wallet was created but never populated. The range is now sent only for
  ranged (`…/*`) descriptors. Bad input also gets a clearer message ("not an
  xpub/ypub/zpub, an output descriptor, or an address").

## [1.14.2] - 2026-07-12

### Fixed

- **The dashboard now keeps matching space below the last card.** The bottom
  buffer had been set on the flex container, and browsers drop a flex
  container's padding on the overflow (bottom) edge when the content is taller
  than the viewport — so the last card sat flush against the bottom. The buffer
  now lives on the content column, where it's always part of the scroll area
  (top and bottom now match).

## [1.14.1] - 2026-07-12

### Fixed

- **The dashboard header no longer clips at the top in a short window.** The
  cards are centered in the viewport, so a stack taller than the window — a short
  window, or a browser banner (e.g. Chrome's "make default" prompt) eating
  height — pushed the header off the top edge with no way to scroll up to it. The
  layout now falls back to top-aligned when it overflows (`align-items: safe
  center`) and carries a top/bottom buffer.

## [1.14.0] - 2026-07-12

### Added

- **Manage watch-only wallets from the dashboard.** A "Watch-only balances" card
  now lets you add a wallet (label + `xpub`/descriptor + optional birthday) and
  remove it with a ✕ — no config editing. The list is saved to the stack (held in
  Bitcoin Core, with the roster on a new `dashboard_state` volume) and survives
  restarts; `config.json`'s `wallets` becomes an optional first-run seed. A total
  is shown only when you have more than one wallet. See
  [docs/watch-only.md](docs/watch-only.md).

### Security

- The add/remove endpoints turn the dashboard into a control surface, so they're
  guarded: the existing dashboard password (when set) gates them, a required
  `X-Requested-With` header blocks cross-site (CSRF) writes, keys are validated
  server-side, the wallet count is capped, and the card warns when no password is
  set. Wallet names render via `textContent` (no HTML injection).

## [1.13.0] - 2026-07-12

### Added

- **Watch-only balances.** Add public keys to `config.json` (`wallets: [{ name,
  key, birthday? }]`) and the dashboard shows each balance and a total, read
  straight off your own node — your addresses never touch a block explorer.
  `key` accepts an `xpub`/`ypub`/`zpub` (script type inferred from the prefix,
  SLIP-132 keys converted to the `xpub` Core needs) or a full output descriptor
  for exact control. The node holds one spend-disabled descriptor wallet per
  key, so there are no private keys and no spend risk; the first import rescans
  the chain (bounded by an optional `birthday`) and shows `scanning…` until
  done. Full node only — a pruned node can't rescan history, so it's skipped
  there. See [docs/watch-only.md](docs/watch-only.md).

## [1.12.2] - 2026-07-12

### Fixed

- **The update checker only alerts on a strictly newer version now.** It
  compared the running version against the latest release with `!=`, so if
  the box was briefly ahead of the GitHub "latest release" (e.g. right after
  a deploy, before the API propagated), it would report the *older* release
  as "available" — "🆕 stack v1.12.0 available (running v1.12.1)". Now it
  compares numeric version parts and stays quiet unless a genuinely newer
  release exists. Same fix for the Bitcoin Core check.

## [1.12.1] - 2026-07-12

### Fixed

- **Sub-1 sat/vB fees showed "—".** A quiet-mempool estimate like 0.44 sat/vB
  was rounded to 0, and 0 rendered as a dash (so "1h" showed "—"). Fees now
  keep one decimal (e.g. `0.4`); a dash means genuinely no estimate.
- **The displayed stack version could go stale.** It came from `.env`, so a
  deploy that ran `docker compose build && up` without re-running
  `configure.sh` kept an old version (and tripped the update badge). The
  version is now baked into the dashboard image (`COPY VERSION`; the build
  context is the repo root), so it always matches the running code.

## [1.12.0] - 2026-07-11

### Added

- **Fee sparkline (back).** A 24-hour sparkline of the next-block fee under
  the fee row, from a small in-memory series sampled once a minute (`fee_history`,
  served at `/api/fees`). Fee-only — no height series or tower dependency.
- **Tab favicon** — a bitcoin ₿ mark, so the dashboard is recognisable in a
  browser tab.

## [1.11.1] - 2026-07-11

### Fixed

- Unfilled tower cubes now recede as a faint grid instead of a solid fill —
  in light mode the "not yet" slots were brighter than the filled gold and
  read as a highlighted patch next to the pulsing loading cube. Now only the
  single loading slot stands out.

## [1.11.0] - 2026-07-11

### Changed

- **The tower fills to the time of day, driven purely by the clock.** A day's
  layer now fills to where the day should be at ~10-minute spacing (one cube
  per 10 UTC minutes) rather than tracking exact block arrivals — so it's
  solid up to "now" (e.g. nearly full late in the UTC day). The single
  estimate marker is gone; the fill *is* the estimate, with the loading slot
  pulsing.

### Removed

- The in-memory history sampler, the fee/height sparklines, and the
  `/api/history` endpoint — no local history is tracked anymore. The tower
  needs only the clock and the block height, so the node-timestamp
  "blocks today" lookup is gone too.

## [1.10.1] - 2026-07-11

### Fixed

- **The tower's "blocks today" is now correct immediately and survives a
  restart.** It was counted from an in-memory series pinned at the first
  sample after start, so a mid-day container restart reset the day and the
  tower looked near-empty. It's now computed from the node's own block
  timestamps — a once-a-day binary search for the first block at/after UTC
  midnight — so late in the UTC day it shows a nearly full layer (e.g. ~137
  of 144 at 23:38 UTC), regardless of when the container started.

## [1.10.0] - 2026-07-11

### Added

- **The loading block pulses** in the tower — the cube for the block being
  mined now flashes while it waits, instead of sitting static.
- **Time-of-day estimate marker.** A faint outlined cube marks where the
  day's fill "should" be by now at Bitcoin's ~10-minute spacing, so you can
  see at a glance whether blocks are running ahead of or behind schedule.
  It uses UTC time-of-day, matching the UTC day boundary (Bitcoin block
  timestamps are Unix/UTC time).

## [1.9.0] - 2026-07-11

### Added

- **Fee and block-height sparklines.** The dashboard samples height + fee
  once a minute into an in-memory 24-hour series and draws a sparkline under
  each. Served as JSON at `/api/history` (behind the dashboard's optional
  auth).
- **The tower is now a day-clock.** A 12×12 layer is one UTC day: the first
  cube is the first block after 00:00, cubes fill as blocks arrive through
  the day, and at midnight the day is pushed down and a fresh one starts
  (driven by the real "blocks so far today" count, not a fixed block index).
- **"loading block N" header** above the tower — the next block the network
  is working on.

## [1.8.0] - 2026-07-11

### Changed

- **Healthchecks pings retry until one succeeds.** The dashboard pings every
  5 minutes (matching the recommended check period), but a failed ping now
  retries each minute instead of waiting a full cycle — so a brief Tor blip
  can't trip a tight Healthchecks grace window.
- **Notifications guide rewritten** ([docs/notifications.md](docs/notifications.md)):
  step-by-step Telegram and Healthchecks.io setup, the recommended check
  settings (Period 5 min, Grace 1–2 min) that match the ping cadence, and how
  to route Healthchecks' own alert into the same Telegram group.

## [1.7.0] - 2026-07-11

### Added

- **Mempool & fees on the dashboard** (and `/metrics`): transaction backlog
  (count + size) and sat/vB fee estimates for the next / ~30-min / ~1-hour
  blocks. Shown only once synced (`estimatesmartfee` has no data during
  initial block download). New Prometheus series `bitcoin_mempool_txs`,
  `bitcoin_mempool_bytes`, and `bitcoin_fee_sat_vb{blocks="1|3|6"}`.
- **Opt-in new-block Telegram alert** (`notifications.alert_new_block`,
  default off): a 🟧 alert as the node accepts each new block once synced.
  Off by default because a synced node finds ~144 blocks a day; skips the
  catch-up burst during sync.
- **Supply-chain lint in CI**: gitleaks (secret scan) and hadolint
  (Dockerfile lint), plus GitHub issue/PR templates and a code of conduct.

## [1.6.0] - 2026-07-11

### Changed

- **The dashboard is now published on host port 80** (was 8000), so it's
  reachable at `http://<host>` with no port in the URL. The container still
  serves on 8000 internally.
- **Responsive layout:** on a wide screen the status card sits on the left
  and the block tower gets the right half of the page, so the tower is no
  longer hidden behind the card. On a phone it stays centred with the tower
  behind, and the card no longer overflows a narrow viewport.

## [1.5.0] - 2026-07-11

### Changed

- **The block tower is now live data, not decoration.** A 12×12 layer is
  144 blocks — about a day. The dashboard renders the node's block height
  into the page, and the tower fills a cube per block; when a layer (a day)
  completes it pushes the tower down a level and the oldest layers slide off
  the bottom. It rips upward during initial sync and drifts a single block
  in over ~0.8s once synced. Still theme-aware, throttled, hidden-tab-paused,
  and reduced-motion-safe.

## [1.4.0] - 2026-07-11

### Added

- **Auto light/dark theme** with a top-right toggle (Auto → Light → Dark):
  follows the system preference in auto mode and remembers an explicit
  choice. Styles moved to a served stylesheet built on CSS variables, with
  an inline init script that sets the theme before first paint (no flash).
- **Animated block tower** — a 5×5 isometric tower in the bitcoin accent
  rises endlessly behind the status card, fading in and out at the screen
  edges. Theme-aware, throttled to 30fps, paused on a hidden tab, and
  honours `prefers-reduced-motion`. Purely decorative.
- **In-place refresh** — the status panel updates by polling and swapping
  itself, replacing the full-page `<meta refresh>` so the theme and the
  tower animation never reset.
- Frontend unit tests (`node --test`) for the theme-cycle and tower
  projection/timing logic, wired into CI.

## [1.3.0] - 2026-07-11

### Added

- Dashboard shows the stack version (from the `VERSION` file, via
  `STACK_VERSION`) in the footer and on the sync/loading page.
- Dashboard header badge now always states the node mode — **Full** or
  **Pruned · N GB** — instead of showing a badge only when pruned.

### Changed

- The dashboard's "Version:" row is relabelled **Bitcoin Core:** to
  distinguish the node version from the new stack version.

## [1.2.1] - 2026-07-11

### Fixed

- Dashboard rendered `🆕 <built-in method update of dict object ...>` on
  every page: the stats key `update` shadowed Python's `dict.update` in
  Jinja attribute lookup, which is always truthy. Renamed to
  `update_note`; a regression test pins the default page to badge-free.

## [1.2.0] - 2026-07-11

### Added

- **`./stack` CLI** — `up`/`down`/`restart`/`logs`/`apply`/`status` plus a
  read-only `doctor` report (deps, config freshness, disk, sync, tor,
  onion addresses).
- **`./stack backup` / `restore`** — config, credentials, and onion keys
  in one dated tarball; chain data deliberately excluded.
- **Prometheus `/metrics`** on the dashboard (hand-rolled text format,
  behind the same optional basic auth).
- **Update checker** — daily, over Tor: new Bitcoin Core or stack releases
  trigger a 🆕 Telegram alert and a dashboard badge. Informational only.
- **Egress audit in the e2e** — asserts every established connection from
  the bitcoin and dashboard containers terminates inside the stack subnet;
  the Tor-only claim is now tested, not just configured.
- `VERSION` file (rendered into the stack for the update checker).
- **Release automation** — `scripts/release.sh` preflight (clean tree,
  semver, tag collision, changelog section) + a tag-triggered workflow
  that re-runs the full test gate and publishes the GitHub Release with
  notes extracted from this file and a source tarball. Documented in
  [Releasing](docs/releasing.md).

### Changed

- Self-healing decided as a deliberate non-feature (restart policy covers
  crashes; no Docker-socket access for anything else) — documented in
  [Operations](docs/operations.md#self-healing-a-deliberate-non-feature).

## [1.1.0] - 2026-07-11

### Added

- **Telegram alerts** (`notifications.telegram_bot_token` / `telegram_chat_id`):
  debounced one-way alerts — node down/recovered, initial sync complete,
  disk low, startup heartbeat. Sent over Tor (`socks5h`), so alerts are
  never a clearnet beacon. No commands, nothing controls the node.
- **Healthchecks.io dead-man's switch** (`notifications.healthchecks_url`):
  a ping every 5 minutes (`/fail` variant while the node's RPC is down),
  also over Tor — an outside service alerts you when the whole box goes
  dark, the one failure an on-box monitor can't report.
- **Dashboard over Tor** (`dashboard.onion`): publishes the dashboard as an
  onion service for remote access with no port-forwarding; `configure.sh`
  warns if enabled without `dashboard.password`.
- Monitor unit tests, e2e assertion for the onion provisioning, and a
  [notifications guide](docs/notifications.md).

## [1.0.0] - 2026-07-11

First tagged release.

### Added

- **Pruned node support** — `bitcoin.prune_mb` in `config.json` (`0` = full
  node, `≥550` = pruned target in MB). Full validation in ~30 GB.
- **Optional inbound onion service** — `bitcoin.inbound_onion: true` has
  bitcoind register a Tor onion service (cookie-authed control port) and
  serve blocks to the network without exposing the host IP or opening a
  host port.
- **Optional dashboard authentication** — `dashboard.password` enables HTTP
  basic auth.
- **Dashboard: pruned badge and low-disk warning** — shows pruned status
  with the prune target, and flags free space under 50 GB.
- **rpcauth** — bitcoind receives a salted HMAC instead of the plaintext
  RPC password; `docker inspect bitcoin` reveals no secret. Health checks
  authenticate with Core's cookie file.
- **Test suite** — configure.sh end-to-end test, docker-compose contract
  test, dashboard unit tests, and a full-stack e2e boot test that runs in
  CI (pruned, onion-enabled, auth-enabled).
- **CI + supply-chain hygiene** — everything pinned (image digests, pip
  versions, GitHub Actions by SHA) and maintained by weekly Dependabot.
- **Docs** — getting started, hardware, configuration, architecture,
  operations; SECURITY.md threat model; CONTRIBUTING.md; MIT license.
- Container log rotation (10 MB × 3 per service).

### Changed

- **Bitcoin Core image: `lncm/bitcoind:v28.0` → official `bitcoin/bitcoin`
  (v31.1)** — lncm stopped publishing in January 2025; the official images
  track every Core release, so Dependabot catches node upgrades.
- Stack subnet moved to `172.29.0.0/24` (the old `172.28.0.0/24` collides
  with Pithead's network on a shared Docker host).
- Credentials flow `config.json` → gitignored `.env` → container
  environment; no tracked file is ever modified.

### Fixed

- Dashboard Docker build (referenced a misnamed file).
- bitcoind flags silently dropped by YAML line folding in the compose
  entrypoint — the bug that motivated the e2e boot test.
- Tor data directory group ownership (`tor:root` → `tor:tor`) so the
  bitcoin container can read the control-auth cookie via gid 101.

[1.18.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.18.1
[1.18.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.18.0
[1.17.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.17.0
[1.16.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.16.0
[1.15.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.15.1
[1.15.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.15.0
[1.14.2]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.14.2
[1.14.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.14.1
[1.14.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.14.0
[1.13.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.13.0
[1.12.2]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.12.2
[1.12.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.12.1
[1.12.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.12.0
[1.11.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.11.1
[1.11.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.11.0
[1.10.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.10.1
[1.10.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.10.0
[1.9.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.9.0
[1.8.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.8.0
[1.7.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.7.0
[1.6.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.6.0
[1.5.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.5.0
[1.4.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.4.0
[1.3.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.3.0
[1.2.1]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.2.1
[1.2.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.2.0
[1.1.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.1.0
[1.0.0]: https://github.com/VijitSingh97/bitcoin-starter-stack/releases/tag/v1.0.0
