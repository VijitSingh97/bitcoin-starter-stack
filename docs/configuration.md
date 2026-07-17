# Configuration

**`config.json` is optional.** `./stack up` runs with no config at all — it uses
the defaults below and auto-generates the internal RPC credentials. Create a
`config.json` (copy the tracked template, `cp config.example.json config.json`)
only to override something. `configure.sh` renders it into a gitignored `.env`,
which docker compose reads. Tracked files are never modified, so your settings
can't end up in a commit.

## config.json reference

Every key is optional. The template ([config.example.json](../config.example.json))
shows the overridable settings with their defaults:

```json
{
    "bitcoin": {
        "data_dir": "./data/bitcoin",
        "dbcache_mb": 3000,
        "prune_mb": 0,
        "inbound_onion": false,
        "blockfilterindex": false,
        "sync_over_clearnet": false
    },
    "dashboard": {
        "password": "",
        "onion": false
    },
    "notifications": {
        "telegram_bot_token": "",
        "telegram_chat_id": "",
        "healthchecks_url": "",
        "alert_new_block": false
    },
    "wallets": []
}
```

| Key | Default | What it does |
|---|---|---|
| `bitcoin.node_username` | `bitcoin` | Internal RPC username (dashboard ↔ bitcoind, private network). Defaults to `bitcoin`; set it only if you want a different internal username. Letters and numbers only. |
| `bitcoin.node_password` | auto-generated | Internal RPC password. Auto-generated (strong random) unless you set one. bitcoind receives only a salted hash (`rpcauth`); the plaintext goes to the dashboard alone. Letters and numbers only. |
| `bitcoin.data_dir` | `./data/bitcoin` | Where the blockchain lives on the host. Relative paths resolve from the repo root. |
| `bitcoin.dbcache_mb` | `3000` | Bitcoin Core's UTXO cache size in MB. Size it to your RAM — see [Hardware](hardware.md#ram). |
| `bitcoin.prune_mb` | `0` | `0` = full archival node. Any value ≥ `550` keeps only that many MB of recent blocks — see [Pruned node](#pruned-node). |
| `bitcoin.inbound_onion` | `false` | `true` publishes a Tor onion service so your node accepts inbound connections and serves blocks to the network. **Encouraged** — it strengthens the network with **no IP exposure** (it's over Tor); the only cost is some extra bandwidth. See [Inbound onion service](#inbound-onion-service). |
| `bitcoin.blockfilterindex` | `false` | `true` builds a compact block-filter index that makes watch-only wallet rescans dramatically faster (a shared cache reused by every wallet). Full node only (incompatible with `prune_mb`). Costs ~a few GB and a one-time background build. See [Watch-only](watch-only.md#speeding-up-the-first-scan). |
| `bitcoin.sync_over_clearnet` | `false` | `true` runs the initial block download over **clearnet** (hours, vs. days over Tor) — but this **exposes your home IP** to peers during the sync. Onion peers still go through Tor. Set it back to `false` and `./stack apply` once synced to return to Tor-only. Opt-in; leave `false` for a fully private node. |
| `bitcoin.mem_limit_mb` | `0` (unlimited) | Optional memory cap on the bitcoin container, in MB. `0` = no limit (Docker's default). A cap turns a bitcoind memory blowup into a contained container restart instead of a whole-host OOM — worth setting on a RAM-tight box. **Size it above `dbcache_mb`**: leave ~1.5–2 GB of headroom for bitcoind's working set (e.g. on an 8 GB box with `dbcache_mb: 3000`, `5000` is reasonable). Too low and bitcoind gets OOM-killed and restart-loops; `configure.sh` warns if it's not above `dbcache_mb`. |
| `dashboard.password` | `""` (no auth) | Non-empty enables HTTP basic auth on the dashboard (any username, this password). Letters and numbers only. `./stack init` generates one by default (Enter at its prompt); a bare `./stack up` stays open on the LAN. |
| `dashboard.onion` | `false` | `true` publishes the dashboard as a Tor onion service — see [Notifications & Remote Access](notifications.md#dashboard-over-tor). Set a password with it. |
| `notifications.telegram_bot_token` | `""` (off) | With `telegram_chat_id`, enables Telegram alerts (node down/recovered, sync complete, disk low) — see [Notifications](notifications.md#telegram-alerts). |
| `notifications.telegram_chat_id` | `""` (off) | The chat that receives alerts. |
| `notifications.healthchecks_url` | `""` (off) | Healthchecks.io ping URL for a dead-man's switch — see [Notifications](notifications.md#healthchecksio-dead-mans-switch). |
| `notifications.alert_new_block` | `false` | `true` sends a Telegram alert on each new block once synced (~144/day). |
| `wallets` | `[]` | Optional **seed** for watch-only balances — each `{ name, key, birthday? }`, where `key` is an `xpub`/`ypub`/`zpub` or a full output descriptor. Loaded on first start; after that you add/remove wallets from the dashboard UI and this is ignored. Full node only. See [Watch-only](watch-only.md). |

`configure.sh` applies the defaults above for any omitted key, and generates
strong random RPC credentials on first run (reused on later runs).

## Applying changes

```bash
nano config.json
./stack apply    # re-renders .env and recreates only the containers that changed
```

## Pruned node

Set `prune_mb` to run with a fraction of the disk. The node still
downloads and **fully validates** every block — it just discards old block
files afterwards, keeping roughly the configured amount:

```json
"prune_mb": 10000
```

keeps ~10 GB of recent blocks; with the chainstate (~12 GB) and overhead,
total disk lands around 25–30 GB instead of ~800 GB.
`configure.sh` rejects values between 1 and 549 because bitcoind does.

Know the trade-offs before enabling:

- **Enabling is one-way-ish.** Turning pruning on for an existing full
  datadir prunes it down in place. Going back to `prune_mb: 0` later
  requires re-downloading the entire chain.
- A pruned node can't serve historical blocks to other software (some
  wallets and explorers need `txindex`, which pruning excludes).
- The dashboard's "Node Data Size" will show the pruned footprint.

Apply like any other change: edit `config.json`, `./configure.sh`,
`docker compose up -d`.

## Inbound onion service

By default the node is outbound-only. Setting `"inbound_onion": true` has
bitcoind register an onion service over Tor's control port, so other nodes
can fetch blocks from you **without your IP ever being visible** — you
contribute to the network from behind Tor. It's **encouraged**: more reachable
nodes make Bitcoin healthier, and over Tor it's private. The only cost is some
extra outbound bandwidth serving blocks to peers. (`./stack init` offers it as a
prompt.)

Mechanics (already wired, just flip the flag): tor exposes a cookie-authed
control port on the internal network; the tor data volume is mounted
read-only into the bitcoin container, whose process joins tor's group to
read the cookie; bitcoind gets `-listen=1 -listenonion=1 -torcontrol=...`.
Confirm it worked with:

```bash
docker logs bitcoin 2>&1 | grep "tor: Got service ID"
```

No host port is opened — inbound arrives through the Tor network only.

## Reusing an existing node

Already have a synced chain? Point `data_dir` at it and skip the
week-long sync:

```json
"data_dir": "/home/you/.bitcoin"
```

Two requirements:

- The directory must be **owned by uid 1000** (the first user on most
  Ubuntu installs) — the bitcoin container runs as `1000:1000`.
- The chain must come from a compatible Bitcoin Core version — the datadir
  upgrades in place from older releases; this stack currently ships Core
  31.1. Downgrading to an earlier major version on this datadir is one-way
  and not supported.

The dashboard mounts the same directory read-only for its disk-usage
stats.

## What's deliberately not configurable

Static node settings apply to every deployment. RPC bind/allow ranges live in
[build/bitcoin/bitcoin.conf](../build/bitcoin/bitcoin.conf). Tor-only
networking is set in the `docker-compose.yml` bitcoin entrypoint (and
toggled by `bitcoin.sync_over_clearnet` — see the config table above). If you
need to diverge from the routing defaults, edit the entrypoint — but you're
forking the privacy model at that point; read
[Architecture](architecture.md) first.
