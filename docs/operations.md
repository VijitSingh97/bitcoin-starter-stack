# Operations

## Day-to-day commands

| Command | What it does |
|---|---|
| `docker compose up -d` | Start (or apply config changes to) the stack. |
| `docker compose down` | Stop everything. Bitcoin Core gets up to 5 minutes to flush cleanly — let it. |
| `docker compose logs -f [service]` | Follow logs (`tor`, `bitcoin`, or `dashboard`). |
| `docker ps` | Container status including health (`healthy` / `unhealthy`). |
| `docker exec bitcoin bitcoin-cli -datadir=/data getblockchaininfo` | Talk to the node directly (cookie auth, no credentials needed). |

## Health checks

All three services define Docker health checks:

- `tor` — SOCKS port accepting connections (5 min grace for bootstrap).
- `bitcoin` — RPC answers `getblockchaininfo`, authenticated with Core's
  `.cookie` file (30 min grace: RPC returns "warming up" during startup
  block verification).
- `dashboard` — HTTP 200 on port 8000.

`docker ps` shows the state; `docker inspect --format '{{json .State.Health}}' bitcoin`
shows recent probe output when diagnosing.

## Upgrading

- **Bitcoin Core:** the stack uses the official
  [`bitcoin/bitcoin`](https://hub.docker.com/r/bitcoin/bitcoin) image,
  pinned to an exact version and digest in `docker-compose.yml`. Dependabot
  files a PR when a new release is published; CI boots the stack against it
  before you merge. To upgrade manually, bump the tag+digest and
  `docker compose up -d`. Chain data upgrades in place; downgrades across
  major versions are not generally supported, so read the release notes.
- **Dashboard / Tor images:** `git pull`, then
  `docker compose up -d --build`.
- Everything is pinned (image digests, pip versions, action SHAs) and
  Dependabot maintains all of it with weekly PRs.

## Backup

Only two things are worth backing up — both tiny:

- `config.json` (your settings)
- `.env` (rendered credentials — or just re-run `./configure.sh`)

The chain itself is re-derivable from the network. Backing up ~800 GB is
only worth it if a multi-day Tor resync hurts more than the storage does.
If you do: `docker compose down` first — a live copy of `chainstate/` is
corrupt by construction.

## Troubleshooting

**Compose says `run ./configure.sh first`** — exactly that. `.env` is
missing or incomplete.

**Tor never reaches "Bootstrapped 100%"** — your network may block Tor.
Check `docker compose logs tor` for connection failures; a restrictive
firewall needs outbound 443/9001 open.

**bitcoind exits immediately** — almost always data-dir permissions. The
container runs as uid 1000; `ls -ld <data_dir>` should show your user (uid
1000) as owner. Also check `docker compose logs bitcoin` for the actual
error.

**Dashboard stuck on "Initializing"** — the dashboard can't reach RPC.
During startup that's normal (block verification can take minutes). If it
persists: `docker compose logs bitcoin` — and if you recently changed
credentials, make sure you re-ran `./configure.sh` *and*
`docker compose up -d` so both containers got the new values.

**Node syncs but peer count is 0 after hours** — tor container unhealthy or
restarted with a new identity mid-session. `docker compose restart tor bitcoin`.

**Disk filling up** — the dashboard's disk row is the early warning.
Options: a bigger disk, or switch to a pruned node via `prune_mb` in
`config.json` — see [Configuration → Pruned node](configuration.md#pruned-node).
