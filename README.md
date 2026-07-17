<div align="center">

# Bitcoin Starter Stack

### Private Bitcoin full node, routed over Tor

[![CI](https://github.com/VijitSingh97/bitcoin-starter-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/VijitSingh97/bitcoin-starter-stack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: Ubuntu 24.04](https://img.shields.io/badge/Platform-Ubuntu%2024.04-E95420?logo=ubuntu&logoColor=white)
![Tor](https://img.shields.io/badge/Networking-Tor--only-7D4698?logo=torproject&logoColor=white)

Docker Compose stack for a [Bitcoin Core](https://bitcoincore.org/) full node with all P2P
traffic routed through a built-in Tor daemon, plus a lightweight web dashboard for
watching sync progress, peers, and disk usage.

<img src="./images/dashboard.png" width="80%" alt="Bitcoin node dashboard: live node status card, watch-only wallet balances in gold with sparklines above a 3D block tower" />

</div>

---

## What it does

- 🟠 **Full Bitcoin node.** The official Bitcoin Core image (digest-pinned, Dependabot-updated)
  validating the full chain, health-checked by Docker — or a **pruned node** in ~30 GB via one
  config key.
- 🧅 **Tor-only networking.** All P2P traffic goes through the Tor container
  (`onlynet=onion`) — your home IP is never associated with your node. Accepts **inbound
  over a Tor onion service by default** to serve blocks back to the network (no IP
  exposure, no host port); set `inbound_onion: false` to run outbound-only.
- 📊 **Live dashboard.** Sync progress, peers, uptime, pruned status, and disk usage (with a
  low-space warning) on your LAN at port `80` — optionally behind basic auth. RPC stays
  inside the Docker network; nothing but the dashboard port is exposed.
- 🔑 **Credentials handled properly.** Config renders into gitignored files, so a stray
  `git add` can't publish your RPC password — and bitcoind itself gets only a salted
  `rpcauth` hash, never the plaintext.
- ♻️ **Reuse an existing chain.** Point `data_dir` at an already-synced datadir and skip
  the multi-day initial download.
- 📟 **Opt-in alerts & remote access.** Telegram alerts (node down, sync complete, disk
  low), a [Healthchecks.io](https://healthchecks.io/) dead-man's switch for when the whole
  box goes dark, and dashboard access from anywhere via a Tor onion service — all routed
  over Tor. See [Notifications](docs/notifications.md).
- 👀 **Watch-only balances.** Add your `xpub`s (or descriptors) right in the dashboard — each
  balance and a total, read straight off your own node, your addresses never touching a block
  explorer. Add and remove them from the UI; watch-only, so no keys and no spend risk. See
  [Watch-only](docs/watch-only.md).

## 🚀 Quick Start

**Prerequisites:** Ubuntu Server 24.04 with [Docker Engine](https://docs.docker.com/engine/install/ubuntu/),
`jq`, an SSD with ~1 TB free (the chain is ~800 GB and grows — or ~30 GB
[pruned](docs/configuration.md#pruned-node)), and 8 GB+ RAM.
Details in [Hardware Requirements](docs/hardware.md).

```bash
git clone https://github.com/VijitSingh97/bitcoin-starter-stack.git
cd bitcoin-starter-stack   # or unpack the tarball from the latest release
./stack up                 # generates config, creates the data dir, and starts — nothing to edit
```

That's it — no file to edit. `./stack up` writes a `.env` with sensible defaults
and an auto-generated RPC password (username defaults to `bitcoin`), for a full
node over Tor, then starts the stack. It **pulls prebuilt images** (amd64 and
arm64/Raspberry Pi) from GHCR, so
there's nothing to compile — it only builds locally if you're on an unreleased
commit.

Prefer to be asked? **`./stack init`** walks you through the options — a dashboard
password (Enter generates a strong one), a Tor onion, inbound Tor connections, a
fast clearnet initial sync, pruning — each with a default you accept by pressing
Enter. Everything is
optional; you can also set it later by editing `config.json` and running
`./stack apply`. See [Configuration](docs/configuration.md).

Then watch it come up:

```bash
./stack status            # container + health summary
./stack logs tor          # wait for "Bootstrapped 100% (done)"
./stack logs bitcoin      # headers, then block sync
```

`./stack` wraps day-to-day operations (`up`, `down`, `logs`, `status`,
`doctor`, `apply`, `upgrade`, `backup`/`restore`) — see [Operations](docs/operations.md).
Upgrading is one command: **`./stack upgrade`** fetches the latest release,
backs up, and applies it.

The initial block download is ~800 GB over Tor — expect days, with live progress on the
dashboard the whole time. Full walkthrough: [Getting Started](docs/getting-started.md).

## 📈 Monitoring

Open the dashboard at `http://localhost`, or from another machine on your LAN at
`http://<hostname>.local` (needs `avahi-daemon` on the node box).

- **Node mode** — a **Full** or **Pruned** badge in the header.
- **Sync progress** — block height vs. headers, with a progress bar.
- **Peers** — total connections, inbound vs. outbound.
- **Disk** — chain size on disk vs. drive capacity.
- **Mempool & fees** — transaction backlog and sat/vB estimates for the next / ~30-min / ~1-hour
  blocks (once synced), with a 24-hour fee sparkline.
- **Watch-only balances** — add `xpub`s/descriptors from the UI; per-key balances and a total
  (shown once you have more than one), read off your own node ([Watch-only](docs/watch-only.md)).
- **Versions** — Bitcoin Core version in the card, stack version in the footer.
- **Theme** — follows your system light/dark setting; the top-right toggle cycles
  Auto → Light → Dark and remembers your choice.
- **Live block tower** — a day-clock: a 12×12 layer is one UTC day. It fills to the current
  time of day at Bitcoin's ~10-minute spacing (one cube per 10 UTC minutes); the loading
  slot **pulses**, and a **loading block N** header shows the next block. At midnight the
  day is pushed down and a fresh one starts. Driven purely by the clock — no history or node
  lookups. Theme-aware and paused for `prefers-reduced-motion`.

The dashboard has no authentication — it's meant for your LAN only. Don't port-forward
`80` to the internet.

## 🏗️ How it works

```mermaid
flowchart LR
    You(["👤 You · Browser"])
    Net(["🌐 Tor Network"])

    subgraph stack ["🐳 Bitcoin Starter Stack"]
        Dashboard["📊 Dashboard<br/>:80"]
        Bitcoin["🟠 Bitcoin Core"]
        Tor["🧅 Tor"]
    end

    You ==>|HTTP :80| Dashboard
    Dashboard -.->|RPC| Bitcoin
    Bitcoin ==>|SOCKS5| Tor
    Tor <==> Net
```

Three services on an isolated Docker network: `tor` (SOCKS5 proxy), `bitcoin` (Bitcoin Core,
non-root, RPC reachable only from inside the network), and `dashboard` (Flask app polling
the node over RPC). Full breakdown in [Architecture](docs/architecture.md).

## 📚 Documentation

| Guide | What's inside |
|---|---|
| [Getting Started](docs/getting-started.md) | Prerequisites, install, first start, what to expect during sync. |
| [Hardware Requirements](docs/hardware.md) | CPU, RAM, disk sizing — with real numbers from a reference box. |
| [Configuration](docs/configuration.md) | Every `config.json` key, applying changes, reusing an existing node. |
| [Watch-only](docs/watch-only.md) | Show `xpub`/descriptor balances on the dashboard, read off your own node. |
| [Architecture](docs/architecture.md) | The three services, network layout, and privacy model. |
| [Operations](docs/operations.md) | Commands, health checks, upgrades, backup, troubleshooting. |
| [Notifications & Remote Access](docs/notifications.md) | Telegram alerts, a Healthchecks.io dead-man's switch, and reaching the dashboard over Tor. |
| [Releasing](docs/releasing.md) | How versions are cut: VERSION file, changelog discipline, the tag-triggered gate, and tarballs. |

## 🧪 Testing

```bash
tests/run.sh
```

Runs shellcheck, a `configure.sh` end-to-end test, a docker-compose contract test, and the
dashboard's unit tests — the same suite [CI](.github/workflows/ci.yml) runs on every push,
plus a full image build. See [CONTRIBUTING.md](CONTRIBUTING.md).

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK.** This software is provided "as is" without any warranties. Running
a full node is resource-intensive (bandwidth, disk, memory). Understand your firewall setup
before exposing anything beyond your LAN. Security posture and reporting:
[SECURITY.md](SECURITY.md). Licensed [MIT](LICENSE).
