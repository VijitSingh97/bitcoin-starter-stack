# Configuration

**`config.json` is optional.** `./stack up` runs with no config at all — it uses
the defaults below and auto-generates the internal RPC credentials. Create a
`config.json` (copy the tracked template, `cp config.example.json config.json`)
only to override something. `configure.sh` renders it into a gitignored `.env`,
which docker compose reads. Tracked files are never modified, so your settings
can't end up in a commit. `./stack init` and `./stack restore` keep both files
private with mode `600`. The wizard prints the dashboard login and each selected
node's separate login once at the end; restore does not print credentials.

APT installations use `bitcoin-stack` in place of `./stack`. Their config is
`/etc/bitcoin-starter-stack/config.json`; generated credentials and backups live
under `/var/lib/bitcoin-starter-stack`, and chain data defaults to the dedicated
`/var/lib/bitcoin-starter-stack/data/bitcoin` and
`/var/lib/bitcoin-starter-stack/data/monero` directories. Run package commands
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
        "enabled": true,
        "node_username": "admin",
        "data_dir": "./data/bitcoin",
        "dbcache_mb": 128,
        "prune_mb": 10000,
        "inbound_onion": false,
        "blockfilterindex": false,
        "mem_limit_mb": 0,
        "resource_profile": "off",
        "steady_cpus": 1,
        "steady_mem_limit_mb": 2048,
        "rpc_expose": false,
        "rpc_bind_ip": "",
        "rpc_port": 8332
    },
    "monero": {
        "enabled": false,
        "node_username": "admin",
        "data_dir": "./data/monero",
        "resource_profile": "off",
        "steady_cpus": 1,
        "steady_mem_limit_mb": 2048,
        "rpc_expose": false,
        "rpc_bind_ip": "",
        "rpc_port": 18081,
        "zmq_expose": false,
        "zmq_bind_ip": "",
        "zmq_port": 18083
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
        "alert_new_block": false,
        "alert_new_block_monero": false
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
| `bitcoin.enabled` | `true` | Runs the Bitcoin node. Set false for a Monero-only installation. |
| `bitcoin.node_username` | `admin` | RPC username used by the dashboard and optional LAN wallet connections. Letters and numbers only. |
| `bitcoin.node_password` | auto-generated | Separate Bitcoin RPC password. Existing explicit or rendered credentials remain unchanged. bitcoind receives only a salted hash (`rpcauth`). Letters and numbers only; LAN exposure requires at least 24 characters. |
| `bitcoin.data_dir` | `./data/bitcoin` (source), `/var/lib/bitcoin-starter-stack/data/bitcoin` (APT) | Where the blockchain lives on the host. Relative source paths resolve from the repo root. |
| `bitcoin.dbcache_mb` | `128` | Bitcoin Core's UTXO cache size in MB. Size it to your RAM — see [Hardware](hardware.md#ram). Existing installs keep their rendered cache setting when this key is omitted; the Compose fallback remains 3000 for older `.env` files that predate this setting. |
| `bitcoin.prune_mb` | `10000` | Keeps about 10 GB of recent block files after full validation. Existing explicit configuration and rendered state remain unchanged. `0` remains an advanced manual archival setting; any nonzero value must be ≥ `550`. See [Pruned node](#pruned-node). |
| `bitcoin.inbound_onion` | `false` | `true` publishes a Tor onion service so your node accepts inbound connections and serves available blocks with no IP exposure. See [Inbound onion service](#inbound-onion-service). |
| `bitcoin.blockfilterindex` | `false` | Advanced archival-node compatibility setting. It is incompatible with pruning and is not needed for the default pruned watch-only balance scan. |
| `bitcoin.mem_limit_mb` | `0` (unlimited) | Optional memory cap on the bitcoin container, in MB. `0` = no limit (Docker's default). A cap turns a bitcoind memory blowup into a contained container restart instead of a whole-host OOM. **Size it above `dbcache_mb`** and leave additional room for Core's workload-dependent memory outside the cache. There is no universal fixed margin; monitor actual usage because a low cap can make bitcoind restart-loop. `configure.sh` warns if the cap is not above `dbcache_mb`. |
| `bitcoin.rpc_expose` | `false` | `true` exposes authenticated Bitcoin RPC to a trusted private LAN through the Tor container's TCP relay. See [LAN wallet RPC](#lan-wallet-rpc-opt-in). |
| `bitcoin.rpc_bind_ip` | `""` | Private IPv4 address assigned to this host for the opt-in RPC listener. Required when `rpc_expose` is true. Public, wildcard, loopback, malformed, and IPv6 addresses are rejected. |
| `bitcoin.rpc_port` | `8332` | Host port for the opt-in RPC listener (`1`–`65535`). The internal Core RPC port remains `8332`. |
| `bitcoin.resource_profile` | `off`; `compact` for a node selected by the APT wizard | Experimental APT-only profile: initial sync is uncapped, then a host timer applies the configured steady caps after three spaced, healthy, current sync checks. Existing and source installs remain off. Explicit operator limits take precedence. |
| `bitcoin.steady_cpus` | `1` | Post-sync CPU ceiling when `resource_profile` is `compact`. A JSON number from `0.01` to `256` with at most two decimal places; fractional values such as `0.5` work. |
| `bitcoin.steady_mem_limit_mb` | `2048` | Post-sync memory ceiling in MiB when `resource_profile` is `compact`. A whole JSON number from `257` to `1048576`. Memory plus swap is capped to this same value, so extra swap cannot hide an undersized budget. |
| `monero.enabled` | `false` | Runs the pruned Monero node and adds its health card to the dashboard. |
| `monero.node_username` | `admin` | Digest-auth username for restricted Monero RPC. |
| `monero.node_password` | auto-generated | Separate Digest-auth password for restricted Monero RPC. LAN exposure requires at least 24 letters or numbers. |
| `monero.data_dir` | `./data/monero` (source), `/var/lib/bitcoin-starter-stack/data/monero` (APT) | Monero blockchain data on the host. The node always uses pruned storage. |
| `monero.resource_profile` | `off`; `compact` for a node selected by the APT wizard | The same experimental per-node limit as Bitcoin. Sustained Monero operation at 2 GiB remains unqualified. |
| `monero.steady_cpus` | `1` | Monero's independent post-sync CPU ceiling; same format and range as Bitcoin. |
| `monero.steady_mem_limit_mb` | `2048` | Monero's independent post-sync memory ceiling in MiB; same format and range as Bitcoin. The view-only wallet service is additional. |
| `monero.rpc_expose` | `false` | Publishes restricted Digest-auth RPC to one trusted private-LAN address. |
| `monero.rpc_bind_ip` | `""` | Private IPv4 address assigned to this host. Required when Monero RPC exposure is enabled. |
| `monero.rpc_port` | `18081` | Host port for the opt-in restricted RPC relay. |
| `monero.zmq_expose` | `false` | Publishes the Monero ZMQ feed to one trusted private-LAN address for software such as P2Pool. ZMQ has no application authentication. |
| `monero.zmq_bind_ip` | `""` | Private IPv4 address assigned to this host. Required when ZMQ exposure is enabled. |
| `monero.zmq_port` | `18083` | Host port for the opt-in ZMQ relay. |
| `dashboard.password` | auto-generated | Enables basic auth on fresh installs. It is separate from both node passwords. The wizard prints the selected credentials once after setup. |
| `dashboard.onion` | `false` | `true` publishes the dashboard as a Tor onion service — see [Notifications & Remote Access](notifications.md#dashboard-over-tor). Set a password with it. |
| `dashboard.control` | `false` | `true` shows an **Upgrade now** button on the dashboard when a newer release is available. `./stack up`/`apply` start and manage the host-side agent for you; set a `dashboard.password` too. See [Upgrade button](operations.md#upgrade-button-opt-in). |
| `dashboard.bind_ip` | `127.0.0.1` | Host address for dashboard port 80. Use loopback for access from this machine only, or an RFC1918 address (`10/8`, `172.16/12`, or `192.168/16`) assigned to this host for LAN access. Public, wildcard, and IPv6 binds are rejected. |
| `notifications.telegram_bot_token` | `""` (off) | With `telegram_chat_id`, enables Telegram alerts (node down/recovered, sync complete, disk low) — see [Notifications](notifications.md#telegram-alerts). |
| `notifications.telegram_chat_id` | `""` (off) | The chat that receives alerts. |
| `notifications.healthchecks_url` | `""` (off) | Healthchecks.io ping URL for a dead-man's switch — see [Notifications](notifications.md#healthchecksio-dead-mans-switch). |
| `notifications.alert_new_block` | `false` | `true` sends a Telegram alert on each new block once synced (~144/day). |
| `notifications.alert_new_block_monero` | `false` | Monero's independent new-block Telegram alerts once synced (~720/day). The legacy `alert_new_block` key continues to mean Bitcoin. |
| `wallets` | Binance public example | First-start **seed** for watch-only balances — each `{ name, key, birthday? }`, where `key` is a public extended key, public descriptor, or address. The example is clearly marked and excluded from personal totals. Set `[]` to opt out. After first start the saved dashboard list is authoritative. Personal wallet views and all changes require a dashboard password. See [Watch-only](watch-only.md). |

`configure.sh` applies the defaults above for any omitted key, and generates
strong random RPC credentials on first run (reused on later runs).
Starting and applying use local images only. See [Tor-only networking](privacy.md)
for the boundary between host downloads and Tor-only runtime traffic.

Fresh installs generate independent dashboard, Bitcoin RPC, Monero daemon RPC,
Monero wallet RPC, and encrypted-wallet-file passwords. Read them locally from
the mode-600 `.env`; upgrades preserve existing credentials instead of forcing
a rotation. The wallet RPC is internal-only and is not a LAN connection endpoint.

## Resource caps

Fresh APT wizard installs write these values into each selected node's section.
Existing installations and source installs keep `resource_profile: "off"`
unless explicitly configured; automatic handoff is provided by the APT host
timer. The `steady_*` values have no effect while the profile is `off`.

```json
{
    "bitcoin": {
        "resource_profile": "compact",
        "steady_cpus": 1,
        "steady_mem_limit_mb": 2048
    },
    "monero": {
        "resource_profile": "compact",
        "steady_cpus": 1,
        "steady_mem_limit_mb": 2048
    }
}
```

Edit the existing `/etc/bitcoin-starter-stack/config.json` to change those
fields; keep its other settings. Then run:

```bash
sudo bitcoin-stack apply
```

For example, `steady_cpus: 2` and `steady_mem_limit_mb: 3072` give that node a
2-core, 3-GiB post-sync ceiling. Changing a cap recreates the affected container
and rechecks sync before applying the new values. The chain data stays in its
volume. Set `resource_profile` to `"off"` and apply to stop automatic capping.

The helper uses `bitcoin-starter-stack-resource-profile.timer`; it never runs
inside the dashboard or mounts the Docker socket there. Initial sync remains
uncapped by this profile. Explicit manual Docker limits and the legacy
`bitcoin.mem_limit_mb` cap take precedence, including during sync.

After three spaced, healthy, current sync checks, the helper leaves 256 MiB of
headroom below the configured memory ceiling. It may cleanly restart a synced
node once to release sync memory before rechecking. If usage stays above that
threshold (1792 MiB at the default 2048 MiB ceiling), it leaves the node
uncapped and records why in the system journal. A Bitcoin cache that leaves
less than 256 MiB below the configured memory ceiling also blocks handoff;
lower `bitcoin.dbcache_mb` explicitly before retrying.
Recreated containers are qualified again, so an upgrade can briefly return
them to uncapped operation. The profile is a budget, not a guarantee that a
workload fits; see [hardware estimates and test evidence](hardware.md).

## Shared dashboard settings

Appearance, Telegram, and Healthchecks are global. Per-node settings live in
collapsible sections; block alerts are off by default for each node.

Each node's section lets you enable or disable its LAN RPC listener and, for
Monero, its ZMQ listener, and choose the port. It reuses the node's configured
private LAN address, or the dashboard's configured private LAN address for a
first enable. Addresses stay in server configuration. If neither address is
private, set one there before enabling a port. Public, wildcard, loopback, and
IPv6 listener addresses are rejected. RPC exposure also requires a strong saved
node password. ZMQ has no password, so only enable it on a trusted LAN.

Changes stay in the form until you save. Appearance and notification changes
use **Save**. Port changes use **Save & restart**, with the affected services
listed above the button. LAN listeners live in the Tor relay, so changing them
restarts the relay and dashboard rather than the Bitcoin or Monero daemon.
The dashboard can briefly reconnect; chain data and node sync are preserved.
Port changes require the dashboard password and a running host helper. A
private typed request stays pending while the host checks it. The helper checks
host TCP listeners and Docker's published ports before changing `config.json`
or restarting services. If a selected port is occupied, the panel names the
affected listener and keeps the edits available for correction.

For APT installs, `bitcoin-stack init`, `up`, and `apply` enable
`bitcoin-starter-stack-port-control.timer`. Source installs reuse the host agent
whenever a dashboard password is configured, even when dashboard upgrades are
off. No host control runs inside the dashboard, and it has no Docker socket.
Port settings persist across reboot because the host configuration is updated.

The gear panel also includes **Label towers**, off by default. It saves the
appearance preference in the same private dashboard override file, so it
survives restarts. With labels enabled, each tower also shows its coin price.
**Default currency** starts at USD and applies to those prices and to a panel
when opened. Panel currency selectors can still change the current view.
Resetting to server configuration hides the names and restores USD.

Node cards display configured host RPC/ZMQ endpoints under **Open ports**.
Disabled services have no endpoint, and disabling a node disables its relays.
This view describes configuration; it is not a live port scan. Internal Monero
administration RPC is never shown as a wallet connection endpoint.

## Applying changes

The dashboard gear can change Telegram, Healthchecks, and `alert_new_block`
without restarting the node. It saves a separate persistent JSON override; see
[Dashboard settings](notifications.md#dashboard-settings). Personal wallets are
already managed by the watch-only card and require a dashboard password.
Notification changes follow the dashboard's optional password and work from
localhost, the private LAN, or the onion dashboard.

Monero view-only wallets are also managed in the dashboard, not in `config.json`.
Use the Monero card to submit a mainnet primary address and private view key, with
an optional restore height and signed key-image JSON. Never place a view key,
private spend key, seed phrase, or key images in this tracked configuration.
See [Watch-only balances](watch-only.md#monero-view-only-wallets).

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
