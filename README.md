<div align="center">

# Node Starter Stack

### A very lightweight dashboard for monitoring your new or existing nodes.

[![CI](https://github.com/VijitSingh97/bitcoin-starter-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/VijitSingh97/bitcoin-starter-stack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: Ubuntu 24.04](https://img.shields.io/badge/Platform-Ubuntu%2024.04-E95420?logo=ubuntu&logoColor=white)
![Runtime: Tor-only](https://img.shields.io/badge/Runtime-Tor--only-7D4698?logo=torproject&logoColor=white)

Run [Bitcoin Core](https://bitcoincore.org/), [Monero](https://www.getmonero.org/),
or both, with a small Go dashboard. Pick the gold Bitcoin tower or the orange
Monero tower to open its status card. Running services use Tor for public
internet traffic; the dashboard and optional node RPC stay on your trusted LAN.

<img src="./images/nodes.png" width="100%" alt="Node Starter Stack's gold Bitcoin tower and orange Monero tower; click either to open its status card" />

</div>

---

## What it does

- 🪶 **Small dashboard, low overhead.** A single Go binary with no third-party
  runtime dependencies. The full dashboard used about **8 MiB of working memory**
  in our [mini-1 benchmark](https://github.com/VijitSingh97/bitcoin-starter-stack/blob/c9cdd75/experiments/go-dashboard-results/mini-1-full-port-2026-10-27/README.md).
  Node memory and chain storage are separate; this measurement predates Monero support.
- 🟠 **Choose your nodes.** Bitcoin, Monero, or both. Bitcoin keeps a 10 GB recent-block
  budget; allow **30–60 GB total**. Monero uses its pruned database; allow roughly
  **120–150 GiB including growth room**. Both still validate the chain. See the
  [node comparison and planned chains](docs/nodes.md).
- 🧅 **Tor-only runtime networking.** P2P traffic goes through the Tor container.
  Node containers and the dashboard cannot route directly to the internet,
  and local DNS forwarding is disabled. Bitcoin uses onion peers; inbound connections use an onion
  service when enabled. See the [privacy model](docs/privacy.md).
- 📊 **Live dashboard.** Sync progress, peers, uptime, pruned status, and disk usage (with a
  low-space warning). Start on localhost, or bind port `80` to your private LAN IP;
  add a password and an onion address for remote access. RPC is private by default,
  with optional authenticated access for wallets on your LAN.
- 🔑 **Separate generated logins.** Fresh installs generate different passwords for
  the dashboard and each node's RPC. The username defaults to `admin`; the wizard
  prints the selected services' credentials once. Existing passwords are preserved. Config
  renders into gitignored files, so a stray
  `git add` can't publish your RPC password — and bitcoind itself gets only a salted
  `rpcauth` hash, never the plaintext.
- ♻️ **Reuse an existing chain.** Point `data_dir` at an already-synced datadir and skip
  the multi-day initial download.
- 📟 **Opt-in Bitcoin alerts & remote access.** Telegram alerts (node down, sync complete, disk
  low), a [Healthchecks.io](https://healthchecks.io/) dead-man's switch for when the whole
  box goes dark, and dashboard access from anywhere via a Tor onion service — all routed
  over Tor. See [Notifications](docs/notifications.md).
- ⚙️ **Notification settings that stick.** Configure Telegram, Healthchecks, and
  new-block alerts from the gear menu on localhost, your private LAN, or the onion dashboard.
  Saved values are visible in the settings panel, and a separate JSON override survives
  reboots and upgrades.
- 👀 **Bitcoin balances from your own node.** Import an address, `xpub`, `zpub`, or public
  descriptor. A pruned node scans its live UTXO set without an external address indexer;
  new imports stay pending until that scan confirms and caches a balance. A clearly
  marked public Binance
  address gives fresh installs an example; it is excluded from your totals.
  [How watch-only works](docs/watch-only.md).
- 👁️ **Monero view-only wallets.** Add a main address and private view key from the
  password-protected Monero card. No private spend key or seed is accepted, and the
  dashboard cannot sign or send. Optional signed key images make spent/current balance
  tracking accurate; without them the amount is clearly labeled received-only.
- 🔌 **Monero remote node for Pithead.** Independently enable restricted, authenticated
  Monero RPC and the optional ZMQ publisher on your private LAN.
- 💱 **BTC and XMR in your currency.** USD, EUR, GBP, INR, CAD, AUD, JPY, RUB, and CNY.
  CoinGecko quotes are fetched through Tor, cached, and labeled when stale.
- ⬆️ **One-command upgrades.** `./stack upgrade` fetches the latest release, backs up, and
  applies it — or flip on `dashboard.control` (one question in `./stack init`) and upgrade
  with a button from the dashboard; the stack runs the host-side agent for you.
- 🔭 **Knows when it's stale.** A daily update check (over Tor) surfaces new stack releases on
  the dashboard, and a Prometheus `/metrics` endpoint plugs into whatever
  monitoring you already run.

## 🚀 Fresh install

You need Ubuntu Server 24.04, Docker Engine with Compose 2.33.1 or newer,
`jq`, `openssl`, `curl`, and an SSD. Allow 30–60 GB for Bitcoin and about
120–150 GiB for Monero. Our steady-operation target is **1 CPU and 2 GB RAM per
node**, plus shared Docker, Tor, dashboard, and operating-system overhead.
This is a test target, not a proven minimum: Bitcoin has passed a short capped
trial, and Monero still needs a full capped stability test. Initial sync may use
all available CPU and RAM. A host with only 2 GB total cannot give a node a full
2 GB while also providing room for the operating system. See
[Hardware Requirements](docs/hardware.md).

### 1. Install, then run the wizard

The Ubuntu APT package is prepared for the next release. The feed and signing
key are not public yet. When that release is published, first follow the
[official feed and signing-key setup](docs/privacy.md#package-feed), then run:

```bash
sudo apt update
sudo apt install bitcoin-starter-stack
sudo bitcoin-stack init
```

Package installation is inert: it does not start containers or launch setup.
Run `sudo bitcoin-stack init` explicitly. For a downloaded `.deb`, replace the
install command with `sudo apt install ./bitcoin-starter-stack_VERSION_all.deb`,
then run the same wizard. The first package release supports fresh installs; it
does not migrate an existing source-managed production node.

Until the feed is public, install the published release tarball:

```bash
curl --fail --location --output bitcoin-starter-stack.tar.gz \
  https://github.com/VijitSingh97/bitcoin-starter-stack/releases/latest/download/bitcoin-starter-stack.tar.gz
tar -xzf bitcoin-starter-stack.tar.gz
cd bitcoin-starter-stack
./stack init
```

Development branches use unpublished image tags and need their images built in
a separate development environment; they are not a fresh-install path.

### 2. Accept the safe defaults

Choose Bitcoin, Monero, or both. Press Enter at the dashboard password prompt
to generate a strong password. Each selected node gets its own different RPC
password, with username `admin`. The wizard prints the credentials once at the
end; save them in your password manager. A package install choosing both looks like:

```text
Dashboard password (letters/numbers) [Enter = strong random]:
Nodes to run — bitcoin, monero (experimental), or both [bitcoin]: both
Dashboard bind address (loopback or private LAN) [127.0.0.1]:
Bitcoin data directory [/var/lib/bitcoin-starter-stack/data/bitcoin]:
Expose Bitcoin RPC to trusted LAN wallet apps? [y/N] n
Recent-block retention in GB [10]:
Monero data directory [/var/lib/bitcoin-starter-stack/data/monero]:
Expose restricted Monero RPC to trusted LAN apps? [y/N] n
Expose Monero ZMQ to a trusted LAN P2Pool host? [y/N] n
Download missing containers and start the stack now? [Y/n]

Generated credentials (shown once):
  Dashboard — username: admin  password: <generated dashboard password>
  Bitcoin RPC — username: admin  password: <different generated Bitcoin password>
  Monero RPC — username: admin  password: <different generated Monero password>
```

Press Enter at the final question. Docker downloads the published container
images using the host's normal network settings, then the stack starts. The
wizard does not change Docker's proxy or daemon configuration. These initial
APT and container downloads happen on the host; once running, node peers,
prices, alerts, and dashboard update checks use the stack's Tor container.

Keep `127.0.0.1` to open the dashboard only on the node. For trusted-LAN access,
enter the server's private IPv4 address, such as `192.168.1.117`; wildcard and
public addresses are rejected. The source wizard uses `./data/bitcoin` and also
asks about the optional Upgrade button, which defaults to off.

Fresh package wizard installs select the experimental compact resource profile:
initial sync is uncapped, then a host timer checks for healthy, current sync
before applying 1 CPU and 2 GiB to each node separately. Existing installs and
source installs keep automatic limits off. This mechanism applies a budget;
the longer stability tests still decide whether that budget is sufficient.

If you answer **n** at the final question, start later with:

```bash
sudo bitcoin-stack pull
sudo bitcoin-stack up
sudo bitcoin-stack status
```

For a source install, use `./stack pull`, `./stack up`, and `./stack status`.
`pull` is the explicit network action; routine `up` and `apply` use local images
only and never build or download implicitly.

### 3. Open the dashboard and let your nodes sync

Open `http://localhost` on the node. If you chose a private LAN address, open
`http://<server-private-ip>` from a trusted device. Keep port 80 off the public
internet. Click a tower to see that chain's progress. Check logs with
`./stack logs bitcoin` or `./stack logs monero` for source installs; packages
use `sudo bitcoin-stack logs bitcoin` or `sudo bitcoin-stack logs monero`.

Watch-only wallets remain pending during initial block download. After sync, the
node scans the live UTXO set and shows confirmed balances; its chart contains
saved balance snapshots, not transaction history, spent outputs, or mempool
activity. Initial sync transfers roughly 900 GB through Tor and can take days.
See [Watch-only balances](docs/watch-only.md).
Monero's initial sync also downloads and validates historical data before
discarding the parts pruning does not retain. A pruned node saves disk, not
the initial validation work. Neither chain has a fixed sync-time guarantee.

Containers use Docker's `unless-stopped` policy. They return after a reboot when
Docker starts at boot, unless you explicitly stopped them. Day-to-day commands,
upgrades, backups, and troubleshooting are in [Operations](docs/operations.md),
and [Getting Started](docs/getting-started.md) has the fuller walkthrough.

## 📈 Monitoring

Open `http://localhost` on the node. After setting a private LAN bind address,
use `http://<server-ip>` or `http://<hostname>.local` (`avahi-daemon` required).
The landing page shows a gold Bitcoin tower and an orange Monero tower. Click
one to zoom in and open its card; close it with **×**, Escape, or a click outside
the panel. Towers extend to the bottom of the screen, grow on hover or keyboard
focus, and show a pulsing loading block on top. Names are hidden by default;
enable **Label towers** in the gear panel to show them. That preference survives
restarts. Disabled nodes show **Not configured** in their card.

Both cards show node version, uptime, connections, sync progress, chain storage,
native fee estimates with a 24-hour graph, and a nine-currency price selector.
Monero also shows mempool size, disk capacity/free space, latest-block age,
difficulty, estimated network hashrate, and view-only balances. Unavailable
metrics show a dash.
The **Open ports** section shows configured LAN RPC/ZMQ access or **Disabled**;
it does not scan ports or expose the internal administration listener.
The following extra features belong to the Bitcoin card:

- **Node mode** — a **Full** or **Pruned** badge in the header.
- **Sync progress** — block height vs. headers, with a progress bar.
- **Peers** — total connections, inbound vs. outbound.
- **Disk** — chain size on disk vs. drive capacity.
- **Mempool & fees** — transaction backlog and sat/vB estimates for the next / ~30-min / ~1-hour
  blocks (once synced), with a 24-hour fee sparkline.
- **Watch-only balances** — add `xpub`s/descriptors from the UI; per-key balances and a total
  (shown for multiple personal wallets), read off your own node. The public example
  is excluded from personal totals; first scans stay pending and show their scan-height
  freshness until a result is cached
  ([Watch-only](docs/watch-only.md)).
- **BTC price** — CoinGecko quotes in USD, EUR, GBP, INR, CAD, AUD, JPY, RUB, or CNY, fetched through
  Tor every five minutes. The selector remembers your currency; stale quotes are labeled.
- **Versions** — Bitcoin Core version in the card, stack version in the footer.
- **Theme** — follows your system light/dark setting; the top-right toggle cycles
  Auto → Light → Dark and remembers your choice.
- **Live block tower** — a day-clock: a 12×12 layer is one UTC day. It fills to the current
  time of day at Bitcoin's ~10-minute spacing (one cube per 10 UTC minutes); the loading
  slot **pulses**, and a **loading block N** header shows the next block. At midnight the
  day is pushed down and a fresh one starts. Driven purely by the clock — no history or node
  lookups. Theme-aware and paused for `prefers-reduced-motion`.

The Monero card has the same price, fee-history, status, disk, uptime, and wallet
sections. Its fees are native XMR-per-kB estimates. Monero wallet rows remain
pending during their first scan; amounts are verified as current only when fresh,
complete key-image coverage is present. Notifications remain Bitcoin-only.

The status page, notification gear, and public example can be used without a
password; when configured, the password protects the whole dashboard. Personal
wallet views, wallet changes, and upgrades require one. LAN HTTP is unencrypted:
use a trusted LAN or the onion service, and keep port `80` off the public internet.

## 🏗️ How it works

```mermaid
flowchart LR
    You(["👤 You · Browser"])
    Net(["🌐 Tor Network"])

    subgraph stack ["🐳 Node Starter Stack"]
        Dashboard["📊 Dashboard<br/>:80"]
        Bitcoin["🟠 Bitcoin Core"]
        Monero["🟠 Monero"]
        MoneroWallet["👁️ Monero view-only wallet"]
        Tor["🧅 Tor"]
    end

    You ==>|LAN HTTP :80| Tor
    Tor -->|Fixed local relay| Dashboard
    Dashboard -.->|RPC| Bitcoin
    Dashboard -.->|Internal Digest RPC| Monero
    Dashboard -.->|Internal authenticated RPC| MoneroWallet
    MoneroWallet -.->|Internal Digest RPC| Monero
    Bitcoin ==>|SOCKS5| Tor
    Monero ==>|SOCKS5| Tor
    Tor <==> Net
```

Bitcoin alone uses three containers, Monero alone uses four, and both use five.
Nodes and the Go dashboard share an internal network;
only Tor joins an external network. The Tor container also forwards the private
LAN dashboard port to its fixed internal destination.
[Architecture](docs/architecture.md) explains the layout; [Privacy](docs/privacy.md)
covers downloads, DNS, and the limits of the guarantee.

## 📚 Documentation

| Guide | What's inside |
|---|---|
| [Getting Started](docs/getting-started.md) | Prerequisites, install, first start, what to expect during sync. |
| [Nodes and roadmap](docs/nodes.md) | Bitcoin/Monero setup, Pithead remote-node settings, and other chain candidates. |
| [Hardware Requirements](docs/hardware.md) | CPU, RAM, disk sizing — with real numbers from a reference box. |
| [Configuration](docs/configuration.md) | Every `config.json` key, applying changes, reusing an existing node. |
| [Watch-only](docs/watch-only.md) | Show `xpub`/descriptor balances on the dashboard, read off your own node. |
| [Tor & Privacy](docs/privacy.md) | Enforced runtime routing, LAN access, and the host-download boundary. |
| [Architecture](docs/architecture.md) | Services, network layout, and privacy model. |
| [Operations](docs/operations.md) | Commands, health checks, upgrades, backup, troubleshooting. |
| [Notifications & Remote Access](docs/notifications.md) | Telegram alerts, a Healthchecks.io dead-man's switch, and reaching the dashboard over Tor. |
| [Releasing](https://github.com/VijitSingh97/bitcoin-starter-stack/blob/main/docs/releasing.md) | Maintainer guide to versions, release gates, and tarballs. |

## 🧪 Testing

Tests and development tools are kept in the Git checkout. Release downloads contain
the runtime source, configuration, license, security policy, changelog, and user guides;
they omit tests, parity fixtures, benchmarks, screenshots, and maintainer tools.

```bash
tests/run.sh
```

Runs shellcheck, `configure.sh` and CLI tests, a docker-compose contract test, a
release-consistency check, an upgrade-path test, Go race/vet/unit checks, the retained Python
reference suite, cross-runtime HTTP parity tests, frontend tests, and a real end-to-end boot
whose **egress tests attempt direct IP and DNS access with Tor stopped** —
the same suite [CI](.github/workflows/ci.yml) runs on every push, plus a full image build,
secret scanning (gitleaks), and Dockerfile lint (hadolint). See
[CONTRIBUTING.md](https://github.com/VijitSingh97/bitcoin-starter-stack/blob/main/CONTRIBUTING.md).

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK.** This software is provided "as is" without any warranties. Running
a full node is resource-intensive (bandwidth, disk, memory). Understand your firewall setup
before exposing anything beyond your LAN. Security posture and reporting:
[SECURITY.md](SECURITY.md). Licensed [MIT](LICENSE).

The screenshot uses public and fictional demo data. “Your Wallet” illustrates a
pending import. A single public address is not an exchange’s total reserves or
proof of solvency.

The dashboard runtime is Go; Python remains in the development test harness only.
Bitcoin imports accept public material only. Monero view-only imports require a
private view key, but never a private spend key, seed phrase, signing key, or send permission.
