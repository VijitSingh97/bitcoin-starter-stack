# Operations

## Day-to-day commands

Everything runs through `./stack` (thin, shellcheck-clean wrappers — plain
`docker compose` works too):

| Command | What it does |
|---|---|
| `./stack up` / `down` / `restart [svc]` | Start / stop / restart. Bitcoin Core gets up to 5 minutes to flush on stop — let it. |
| `./stack logs [svc]` | Follow logs (`tor`, `bitcoin`, or `dashboard`). |
| `./stack apply` | Re-render `.env` from `config.json` and apply the changes. |
| `./stack status` | Container + health summary; exits non-zero if anything is down. |
| `./stack doctor` | Read-only health report: deps, config freshness, disk, containers, sync state, tor bootstrap, onion addresses. |
| `./stack backup` / `restore [-y] <archive>` | See [Backup](#backup). |
| `docker exec bitcoin bitcoin-cli -datadir=/data getblockchaininfo` | Talk to the node directly (cookie auth, no credentials needed). |

## Health checks

All three services define Docker health checks:

- `tor` — SOCKS port accepting connections (5 min grace for bootstrap).
- `bitcoin` — RPC answers `getblockchaininfo`, authenticated with Core's
  `.cookie` file (30 min grace: RPC returns "warming up" during startup
  block verification).
- `dashboard` — HTTP 200 on port 8000 (inside the container).

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

```bash
./stack backup                          # writes backups/stack-backup-<ts>.tar.gz
./stack restore backups/stack-backup-<ts>.tar.gz
```

A backup holds everything that can't be re-derived — and nothing else:

- `config.json` and `.env` (settings + credentials)
- the node's inbound-onion key (`onion_v3_private_key`, if enabled)
- the dashboard onion keys (from the tor volume, if enabled)

Losing the onion keys means new `.onion` addresses, so back up after
enabling either onion feature. The chain itself is re-derivable from the
network — backing up ~800 GB is only worth it if a multi-day Tor resync
hurts more than the storage does. If you do copy it: `./stack down`
first — a live copy of `chainstate/` is corrupt by construction.

## Monitoring integrations

- **Prometheus:** the dashboard serves `/metrics` (text format) — block
  height, headers, verification progress, peers in/out, disk, uptime,
  pruned flag, `bitcoin_node_up`, and (once synced) mempool size/bytes and
  `bitcoin_fee_sat_vb` for 1/3/6-block targets. It sits behind the same
  optional basic auth as the dashboard.
- **Telegram / Healthchecks.io:** see [Notifications](notifications.md).
- **Sparklines:** the dashboard samples height + fee once a minute into an
  in-memory 24-hour series (reset on restart) and draws them as sparklines;
  it also backs the tower's day count. Served at `/api/history` (behind the
  same optional auth) if you want the raw JSON.

## Self-healing (a deliberate non-feature)

`restart: unless-stopped` already restarts any container that *crashes*.
The remaining case — running but unhealthy — would need something with
Docker-socket access to act on, and a socket proxy is a bigger attack
surface than the failure it heals on a single-node stack. So: unhealthy
states are surfaced (`./stack status`, `docker ps`, Telegram node-down
alerts) and recovery stays a human decision — `./stack restart <svc>`.

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
