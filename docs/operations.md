# Operations

## Day-to-day commands

Use `./stack` for operations; it prevents implicit image downloads and builds.
The explicit `pull` command uses the host's existing Docker settings.

| Command | What it does |
|---|---|
| `./stack up` / `down` / `restart [svc]` | Start / stop / restart. Bitcoin Core gets up to 5 minutes to flush on stop — let it. |
| `./stack logs [svc]` | Follow logs (`tor`, `bitcoin`, or `dashboard`). |
| `./stack events` | Incident history (down/recovered, failed Healthchecks pings, monitor restarts) from `/state/events.log` — survives restarts and reboots. |
| `./stack apply` | Re-render `.env` from `config.json` and apply the changes. |
| `./stack pull` | Download prebuilt images using the host's Docker settings. |
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
- `dashboard` — any HTTP response on port 8000 (inside the container); a
  401 under basic auth still counts as healthy.

`docker ps` shows the state; `docker inspect --format '{{json .State.Health}}' bitcoin`
shows recent probe output when diagnosing.

## Upgrading

APT installations are upgraded explicitly so package installation never
restarts containers or changes node data. Run:

```bash
sudo bitcoin-stack backup
sudo apt update
sudo apt install --only-upgrade bitcoin-starter-stack
sudo bitcoin-stack apply
```

The dashboard upgrade button is unavailable for APT installations. Source and
release-tarball installations continue to use the flows below.

The first package release is for fresh installations. Do not run
`sudo bitcoin-stack up` beside an existing source checkout: the package refuses to
replace containers whose Compose labels point at another installation. Keep an
existing production node source-managed until a manual migration is planned.
Package mode uses its own `bitcoin-starter-stack-apt` Compose project, so stopped
source installations' named volumes are not adopted by a fresh package install.
That transition must stop and back up the old deployment, set
`bitcoin.data_dir` to the existing absolute chain path, and preserve the Compose
project's dashboard and Tor volumes. Package installation, upgrade, removal,
and purge never perform that migration or change those data paths.

- **One command: `./stack upgrade`.** Fetches the latest release tag through Tor, **backs up
  first**, checks it out, and re-applies — pulling missing prebuilt images with
  host Docker and recreating changed containers. The Git fetch fails closed when
  the stack's Tor proxy is unavailable. It only ever moves **forward** (never
  downgrades) and prints a rollback line if you need it. This is the normal way
  to update the stack itself. (Requires a git checkout; for a tarball install,
  unpack the latest release over it, run `./configure.sh`, then `./stack pull`
  and `./stack apply`.)
- **Bitcoin Core:** the stack uses the official
  [`bitcoin/bitcoin`](https://hub.docker.com/r/bitcoin/bitcoin) image,
  pinned to an exact version and digest in `docker-compose.yml`. Dependabot
  files a PR when a new release is published; CI boots the stack against it
  before you merge. To upgrade manually, bump the tag+digest and
  `./stack pull && ./stack apply`. Chain data upgrades in place; downgrades across
  major versions are not generally supported, so read the release notes.
- **Dashboard / Tor images:** handled by `./stack upgrade`. Local development
  builds require a separately controlled Tor build environment.
- Image digests, Tor packages, and action SHAs are pinned. Dependabot proposes
  image/action updates; Tor package pins also need review during releases.

### Upgrade button (opt-in)

The dashboard can show an **Upgrade now** button when a newer release is
available — one click instead of an SSH session. It's **off by default** and
runs the dashboard as an unprivileged user with no host or Docker access, so
the button never touches the host directly.

Enabling it is one setting: answer **y** at the Upgrade-button question in
`./stack init`, or set `dashboard.control: true` in `config.json` (set a
`dashboard.password` too — the button triggers upgrades) and run
`./stack apply`. That's it: `up`/`apply` start the host-side agent for you,
detached and logging to `~/upgrade-agent.log`, and install a `@reboot` cron
entry so it survives reboots (no sudo needed). Setting `control` back to
`false` disables upgrades. The agent continues to handle validated LAN port
requests while a dashboard password is configured; clearing that password and
applying removes its automatic source-install startup.
`./stack doctor` reports whether the agent is running.

The source upgrade's Git fetch requires the running Tor proxy. A failed Tor check
stops the upgrade without a direct Git fallback.

The button appears only when control is on **and** an update is available. It
writes a request marker to the dashboard's state volume; the agent sees it,
backs up, and runs the same `./stack upgrade` as above. Without the agent
running, clicking the button does nothing — the request just waits.

**Prefer systemd?** Cron can't restart the agent if it crashes mid-run (only
on reboot); a systemd unit can. If the unit below is enabled, the stack leaves
agent management entirely to systemd. Run it as the user who owns the checkout
(and is in the `docker` group) — **not root**, or git refuses the upgrade's
`fetch`/`checkout` with "dubious ownership" on a user-owned repo. Replace
`YOU` with that username:

```ini
# /etc/systemd/system/bitcoin-stack-upgrade-agent.service
[Unit]
Description=bitcoin-starter-stack dashboard upgrade agent
After=docker.service
Requires=docker.service

[Service]
User=YOU
WorkingDirectory=/home/YOU/bitcoin-starter-stack
ExecStart=/home/YOU/bitcoin-starter-stack/stack upgrade-agent
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`sudo systemctl enable --now bitcoin-stack-upgrade-agent`.

## Backup

```bash
./stack backup                          # writes backups/stack-backup-<ts>.tar.gz
./stack restore backups/stack-backup-<ts>.tar.gz
./stack apply
./stack restart dashboard               # reload restored dashboard state
```

APT installations use `sudo bitcoin-stack backup` and write archives under
`/var/lib/bitcoin-starter-stack/backups`; restore and apply with `sudo` as well.

A backup holds the stack configuration and dashboard state, but excludes chain
data and encrypted Monero wallet files:

- `config.json` and `.env` (settings + credentials)
- the node's inbound-onion key (`onion_v3_private_key`, if enabled)
- the dashboard onion keys (from the tor volume, if enabled)
- the full `dashboard_state` volume: watch-only wallet roster and balance
  history (including entries that still need a rescan), pending upgrade
  request, event log, and dashboard-saved notification settings
  (`notification_settings.json`)

The `monero_wallets` volume is intentionally excluded because its encrypted
wallet files contain private view-key material. After restoring onto a new
machine, remove each unavailable Monero row and add it again with its address
and private view key. Release archives and Debian packages never contain this
runtime volume.

Losing the onion keys means new `.onion` addresses, so back up after
enabling either onion feature. The chain itself is re-derivable from the
network — backing up roughly 900 GB is only worth it if a multi-day Tor resync
hurts more than the storage does. If you do copy it: `./stack down`
first — a live copy of `chainstate/` is corrupt by construction.

## Monitoring integrations

- **Prometheus:** the dashboard serves `/metrics` (text format) — block
  height, headers, verification progress, peers in/out, disk, uptime,
  pruned flag, `bitcoin_node_up`, and (once synced) mempool size/bytes and
  `bitcoin_fee_sat_vb` for 1/3/6-block targets. It sits behind the same
  optional basic auth as the dashboard.
- **Telegram / Healthchecks.io:** see [Notifications](notifications.md).
- **Fee sparkline:** the dashboard samples the next-block fee once a minute
  into an in-memory 24-hour series (reset on restart) and draws it under the
  fee row. Served as JSON at `/api/fees` (behind the same optional auth).

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
`./stack apply` so both containers got the new values.

**Node syncs but peer count is 0 after hours** — tor container unhealthy or
restarted with a new identity mid-session. `docker compose restart tor bitcoin`.

**Disk filling up** — the dashboard's disk row is the early warning.
Options: a bigger disk, or switch to a pruned node via `prune_mb` in
`config.json` — see [Configuration → Pruned node](configuration.md#pruned-node).
