# Configuration

**`config.json` is optional.** `./stack up` runs with no config at all — it uses
the defaults below and auto-generates the internal RPC credentials. Create a
`config.json` (copy the tracked template, `cp config.example.json config.json`)
only to override something. `configure.sh` renders it into a gitignored `.env`,
which docker compose reads. Tracked files are never modified, so your settings
can't end up in a commit. `./stack init` and `./stack restore` keep both files
private with mode `600`. The wizard prints the new shared login once at the end;
restore does not print credentials.

APT installations use `bitcoin-stack` in place of `./stack`. Their config is
`/etc/bitcoin-starter-stack/config.json`; generated credentials and backups live
under `/var/lib/bitcoin-starter-stack`, and chain data defaults to the dedicated
`/var/lib/bitcoin-starter-stack/data/bitcoin` directory. Run package commands
with `sudo`. A fresh package installation with no config or prior `.env` defaults
to `prune_mb: 10000`; an explicit config or existing generated value always wins.
`dashboard.control` is unavailable for APT installations because package
upgrades require an explicit administrator command.

## config.json reference

Every key is optional. The template ([config.example.json](../config.example.json))
shows the overridable settings with their defaults:

```json
{
    "bitcoin": {
        "node_username": "admin",
        "data_dir": "./data/bitcoin",
        "dbcache_mb": 3000,
        "prune_mb": 10000,
        "inbound_onion": false,
        "blockfilterindex": false,
        "mem_limit_mb": 0,
        "rpc_expose": false,
        "rpc_bind_ip": "",
        "rpc_port": 8332
    },
    "dashboard": {
        "password": "",
        "onion": false,
        "control": false,
        "bind_ip": "127.0.0.1"
    },
    "notifications": {
        "telegram_bot_token": "",
        "telegram_chat_id": "",
        "healthchecks_url": "",
        "alert_new_block": false
    },
    "wallets": [
        {
            "name": "Binance (public)",
            "key": "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo",
            "birthday": ""
        }
    ]
}
```

| Key | Default | What it does |
|---|---|---|
| `bitcoin.node_username` | `admin` | RPC username used by the dashboard and optional LAN wallet connections. Letters and numbers only. |
| `bitcoin.node_password` | auto-generated | Shared RPC and dashboard password on fresh installs. Existing explicit or rendered credentials remain unchanged. bitcoind receives only a salted hash (`rpcauth`). Letters and numbers only; LAN exposure requires at least 24 characters. |
| `bitcoin.data_dir` | `./data/bitcoin` (source), `/var/lib/bitcoin-starter-stack/data/bitcoin` (APT) | Where the blockchain lives on the host. Relative source paths resolve from the repo root. |
| `bitcoin.dbcache_mb` | `3000` | Bitcoin Core's UTXO cache size in MB. Size it to your RAM — see [Hardware](hardware.md#ram). |
| `bitcoin.prune_mb` | `10000` | Keeps about 10 GB of recent block files after full validation. Existing explicit configuration and rendered state remain unchanged. `0` remains an advanced manual archival setting; any nonzero value must be ≥ `550`. See [Pruned node](#pruned-node). |
| `bitcoin.inbound_onion` | `false` | `true` publishes a Tor onion service so your node accepts inbound connections and serves available blocks with no IP exposure. See [Inbound onion service](#inbound-onion-service). |
| `bitcoin.blockfilterindex` | `false` | Advanced archival-node compatibility setting. It is incompatible with pruning and is not needed for the default pruned watch-only balance scan. |
| `bitcoin.mem_limit_mb` | `0` (unlimited) | Optional memory cap on the bitcoin container, in MB. `0` = no limit (Docker's default). A cap turns a bitcoind memory blowup into a contained container restart instead of a whole-host OOM — worth setting on a RAM-tight box. **Size it above `dbcache_mb`**: leave ~1.5–2 GB of headroom for bitcoind's working set (e.g. on an 8 GB box with `dbcache_mb: 3000`, `5000` is reasonable). Too low and bitcoind gets OOM-killed and restart-loops; `configure.sh` warns if it's not above `dbcache_mb`. |
| `bitcoin.rpc_expose` | `false` | `true` exposes authenticated Bitcoin RPC to a trusted private LAN through the Tor container's TCP relay. See [LAN wallet RPC](#lan-wallet-rpc-opt-in). |
| `bitcoin.rpc_bind_ip` | `""` | Private IPv4 address assigned to this host for the opt-in RPC listener. Required when `rpc_expose` is true. Public, wildcard, loopback, malformed, and IPv6 addresses are rejected. |
| `bitcoin.rpc_port` | `8332` | Host port for the opt-in RPC listener (`1`–`65535`). The internal Core RPC port remains `8332`. |
| `dashboard.password` | shared auto-generated password | Enables basic auth on fresh installs. The wizard prints `admin` and its new shared password once after setup; the current dashboard accepts any basic-auth username with that password. Existing separate credentials remain unchanged. |
| `dashboard.onion` | `false` | `true` publishes the dashboard as a Tor onion service — see [Notifications & Remote Access](notifications.md#dashboard-over-tor). Set a password with it. |
| `dashboard.control` | `false` | `true` shows an **Upgrade now** button on the dashboard when a newer release is available. `./stack up`/`apply` start and manage the host-side agent for you; set a `dashboard.password` too. See [Upgrade button](operations.md#upgrade-button-opt-in). |
| `dashboard.bind_ip` | `127.0.0.1` | Host address for dashboard port 80. Use loopback for access from this machine only, or an RFC1918 address (`10/8`, `172.16/12`, or `192.168/16`) assigned to this host for LAN access. Public, wildcard, and IPv6 binds are rejected. |
| `notifications.telegram_bot_token` | `""` (off) | With `telegram_chat_id`, enables Telegram alerts (node down/recovered, sync complete, disk low) — see [Notifications](notifications.md#telegram-alerts). |
| `notifications.telegram_chat_id` | `""` (off) | The chat that receives alerts. |
| `notifications.healthchecks_url` | `""` (off) | Healthchecks.io ping URL for a dead-man's switch — see [Notifications](notifications.md#healthchecksio-dead-mans-switch). |
| `notifications.alert_new_block` | `false` | `true` sends a Telegram alert on each new block once synced (~144/day). |
| `wallets` | Binance public example | First-start **seed** for watch-only balances — each `{ name, key, birthday? }`, where `key` is a public extended key, public descriptor, or address. The example is clearly marked and excluded from personal totals. Set `[]` to opt out. After first start the saved dashboard list is authoritative. Personal wallet views and all changes require a dashboard password. See [Watch-only](watch-only.md). |

`configure.sh` applies the defaults above for any omitted key, and generates
strong random RPC credentials on first run (reused on later runs).
Starting and applying use local images only. See [Tor-only networking](privacy.md)
for the Tor-verified image download and first-install bootstrap process.

Fresh headless installs use the same generated value for `BITCOIN_RPC_PASSWORD`
and `DASHBOARD_PASSWORD`. Read it locally from the mode-600 `.env`; upgrades
preserve existing usernames and separate passwords instead of forcing a rotation.

## Applying changes

The dashboard gear can change Telegram, Healthchecks, and `alert_new_block`
without restarting the node. It saves a separate persistent JSON override; see
[Dashboard settings](notifications.md#dashboard-settings). Personal wallets are
already managed by the watch-only card and require a dashboard password.
Notification changes follow the dashboard's optional password and work from
localhost, the private LAN, or the onion dashboard.

Keep the following in the server file: Bitcoin storage paths, pruning, indexes,
cache and memory limits, RPC credentials and LAN exposure, `inbound_onion`, and dashboard
password, bind address, onion publication, and `control`. They change storage, process
limits, access, or host privileges and require an explicit server-side apply.

```bash
nano config.json
./stack apply    # re-renders .env and recreates only the containers that changed
```

## Pruned node

The default `prune_mb` runs with a fraction of archival disk. The setting limits
retained block files, not the whole data directory. The node still downloads and
**fully validates** every block before discarding old block files:

```json
"prune_mb": 10000
```

keeps about 10 GB of recent blocks. With the live chainstate currently around
12 GB plus indexes, wallet data, logs, and working headroom, plan for 30–60 GB
total. Initial sync still transfers the whole historical chain, currently
hundreds of GB (roughly 900 GB), and can take days over Tor.
`configure.sh` rejects values between 1 and 549 because bitcoind does.

Know the trade-offs before enabling:

- **Enabling is one-way-ish.** Turning pruning on for an existing full
  datadir prunes it down in place. Going back to `prune_mb: 0` later
  requires re-downloading the entire chain.
- A pruned node can't serve historical blocks to other software. Software that
  requires archival blocks or `txindex` needs a separately planned archival node.
- The dashboard's "Node Data Size" will show the pruned footprint.

Apply like any other change: edit `config.json`, `./configure.sh`,
`./stack apply`.

## Inbound onion service

The node is outbound-only by default. Set `inbound_onion: true` to accept
inbound connections over a Tor onion service. bitcoind
registers an onion service over Tor's control port, so other nodes
can fetch blocks from you **without your IP ever being visible** — you
contribute to the network from behind Tor. The cost is extra outbound bandwidth
serving the blocks retained by the node.

Mechanics (already wired, just flip the flag): tor exposes a cookie-authed
control port on the internal network; the tor data volume is mounted
read-only into the bitcoin container, whose process joins tor's group to
read the cookie; bitcoind gets `-listen=1 -listenonion=1 -torcontrol=...`.
Confirm it worked with:

```bash
docker logs bitcoin 2>&1 | grep "tor: Got service ID"
```

No host port is opened — inbound arrives through the Tor network only.

## LAN wallet RPC (opt-in)

To connect a wallet application on a trusted private LAN, set an address assigned
to the node host and optionally choose a host port:

```json
"bitcoin": {
    "node_username": "wallet",
    "node_password": "usealongrandomvalue123456",
    "rpc_expose": true,
    "rpc_bind_ip": "192.168.1.117",
    "rpc_port": 8332
}
```

Run `./stack apply`, then point the wallet at `http://192.168.1.117:8332`
with `node_username` and `node_password`. If credentials were auto-generated,
read `BITCOIN_RPC_USER` and `BITCOIN_RPC_PASSWORD` from the mode-600 `.env`.

The listener belongs to the Tor container, which forwards TCP to Core on the
internal Docker network. Core keeps its existing `rpcauth` authentication and
Docker-only `rpcallowip`; the Bitcoin container gains no host port or external
route. RPC is unencrypted HTTP. Use it only on a trusted LAN and do not forward
the port through a router. Disable it by setting `rpc_expose` to `false` and
running `./stack apply`.

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
  32.1. Downgrading to an earlier major version on this datadir is one-way
  and not supported.

The dashboard mounts the same directory read-only for its disk-usage
stats.

## What's deliberately not configurable

Static node settings apply to every deployment. Internal RPC bind/allow ranges live in
[build/bitcoin/bitcoin.conf](../build/bitcoin/bitcoin.conf). Tor-only
networking is enforced by an internal application network with only the Tor
container attached to an external bridge. There is no clearnet bypass.
