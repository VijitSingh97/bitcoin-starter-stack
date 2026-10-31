# Getting Started

## Prerequisites

- **Linux** with [Docker Engine](https://docs.docker.com/engine/install/ubuntu/),
  or **macOS** with Docker Desktop. Docker Compose **2.33.1 or newer** must be
  available to the account running Node Manager.
- APT/source installs need `jq`, `openssl`, `curl`, and `iproute2`. Homebrew
  installs bring their command-line dependencies with the formula; Docker is
  still installed separately.
- Hardware per [Hardware Requirements](hardware.md) — Bitcoin plans for
  28–56 GiB SSD space and Monero for 120–150 GiB. The other nodes need expandable
  storage until their current full-sync totals are measured. Bitcoin and Monero
  use an experimental 1 CPU / 2 GiB steady budget; Tari, Litecoin, Dogecoin,
  Bitcoin Cash, and Zcash use 1 CPU / 4 GiB each. Shared services and host
  overhead are additional. Initial sync is uncapped.
  For sync headroom, plan around 2 CPU cores and 4 GiB RAM per node; these are
  estimates, not minimum requirements or measured average usage. More resources
  can shorten validation; Tor and SSD performance also affect sync time.

Optional on Linux: after setting `dashboard.bind_ip` to this host's private address,
`avahi-daemon` lets you reach it at `http://<hostname>.local` from other
machines on your LAN.

On Ubuntu, install `jq`, `openssl`, `curl`, `iproute2`, and optionally
`avahi-daemon` with APT.

## Install

### Homebrew on macOS or Linux

Homebrew support starts with the first release that contains the formula;
current release `v1.31.1` does not include it and the tap is not live yet. Once
published, install it with:

```bash
brew tap vijitsingh97/bitcoin-starter-stack https://github.com/VijitSingh97/bitcoin-starter-stack.git
brew install vijitsingh97/bitcoin-starter-stack/bitcoin-starter-stack
bitcoin-stack init
```

Installation is inert. The explicit `init` command runs the same wizard and
can pull images and start your selected nodes. Homebrew stores configuration
and chain data outside its Cellar so upgrades preserve them:

| Host | Configuration | Generated state and chain data |
|---|---|---|
| macOS | `~/Library/Application Support/bitcoin-starter-stack/config/config.json` | `~/Library/Application Support/bitcoin-starter-stack/state/` and `data/<node>/` |
| Linuxbrew | `${XDG_CONFIG_HOME:-~/.config}/bitcoin-starter-stack/config.json` | `${XDG_DATA_HOME:-~/.local/share}/bitcoin-starter-stack/state/` and `data/<node>/` |

Before first Linuxbrew startup, Node Manager uses an already downloaded local
image to give each empty default data directory the UID expected by its
container (`1000:1000`, or `10001:1000` for Zcash). It never changes a non-empty
directory or a custom data path automatically. If an existing/custom path has
the wrong ownership, startup stops and prints the exact migration command so
you can inspect the path before running it.

After setup, `brew services start bitcoin-starter-stack` keeps the host-side
controls and post-sync resource handoff running after login. It waits for both
configuration and Docker, and never runs setup or pulls images itself. On a
Mac, enable Docker Desktop's start-at-login option; a per-user launch agent
cannot start containers before login. Stopping the Homebrew service stops its
supervisor but leaves nodes running; use `bitcoin-stack down` to stop them.

Homebrew defaults the dashboard to `http://localhost:8080`. See the complete
[Homebrew guide](homebrew.md), including local formula testing and upgrades.
Host-path and control tests run on macOS and Ubuntu CI. The local container
proof used Apple Silicon; a full initial sync and post-sync cap trial on an
Intel Mac has not been completed.

### APT on Ubuntu

The Ubuntu 24.04 APT package will become available with the next release, after
matching amd64 and arm64 dashboard images are published. It installs the
`bitcoin-stack` command globally and keeps mutable files in standard system
locations:

- configuration: `/etc/bitcoin-starter-stack/config.json`
- generated credentials and backups: `/var/lib/bitcoin-starter-stack/`
- chain data: `/var/lib/bitcoin-starter-stack/data/<node>/`

APT installation does not start containers, run setup, or change an existing
checkout. Run `sudo bitcoin-stack init` explicitly after installation. A new
package install defaults to `prune_mb: 10000`; existing configuration and
generated state always win, so an upgrade never converts a full node to pruning.
The first package release supports fresh installations only; keep an existing
source-managed production node on its current upgrade path. Package mode blocks
startup when the fixed service names belong to another Compose installation.
The commands below remain the supported installation until the feed is live.
When the package is released, verify and install its signing key as described in
[Package feed](privacy.md#package-feed), then add the feed:

```bash
echo 'deb [signed-by=/usr/share/keyrings/bitcoin-starter-stack.asc] https://vijitsingh97.github.io/bitcoin-starter-stack ./' \
  | sudo tee /etc/apt/sources.list.d/bitcoin-starter-stack.list
sudo apt update
sudo apt install bitcoin-starter-stack
sudo bitcoin-stack init
```

The wizard lets you select any combination of the supported nodes, downloads missing images with the host's Docker
settings, and starts the stack when you accept its final default. Docker keeps
image layers in its own managed storage. Neither package installation nor the
wizard changes the Docker daemon or its proxy settings.

### Release tarball on Linux

For the current release-tarball installation:

```bash
curl --fail --location --output bitcoin-starter-stack.tar.gz \
  https://github.com/VijitSingh97/bitcoin-starter-stack/releases/latest/download/bitcoin-starter-stack.tar.gz
tar -xzf bitcoin-starter-stack.tar.gz
cd bitcoin-starter-stack
./stack init
```

The tarball's semantic version matches its published container images.
Development branches use unpublished image tags and require images built in a
separate development environment; do not use a branch checkout for installation.

For an offline installation, unpack the source and load all images locally. The
wizard sees that they are present and starts without downloading. `up` and
`apply` never download or build implicitly; `pull` is always an explicit host
network action.

`./stack up` runs `configure.sh` on first launch, which renders a gitignored
`.env` and creates the data directory. With no `config.json` it uses sensible
defaults (10,000 MiB of recent blocks, about 28–56 GiB total disk) and **auto-generates**
separate passwords for the dashboard and each node's RPC (username defaults to
`admin`). Existing generated credentials are retained on subsequent applies.

The wizard prints newly generated credentials once at the end; save them in a
password manager. If you skip it, the mode-600 `.env` contains the baseline
dashboard login. A password later changed in the dashboard is stored as a hash
in dashboard state and takes precedence over that baseline.

The stack's local support images are published prebuilt on GHCR
(`ghcr.io/vijitsingh97/bitcoin-starter-stack-*`) for amd64 and arm64
(Raspberry Pi). `./stack pull` downloads them with the host's existing Docker
settings. The running Bitcoin and dashboard containers remain isolated behind
Tor regardless of how their images were obtained.

Everything is optional. Two ways to customize:

- **`./stack init`** — an interactive wizard that asks for a dashboard
  password (Enter generates one), selected nodes, their data directories,
  a loopback or private-LAN dashboard address, one-click upgrades,
  optional private-LAN RPC, Bitcoin recent-block retention, and whether to download
  missing images and start. Every prompt has a default you accept by pressing Enter.
- Or edit `config.json` by hand (copy `config.example.json`) and run
  `./stack apply`. Stick to letters and numbers in any credentials you set.

The full key reference is in [Configuration](configuration.md).

A default source-install wizard run includes these choices. The dashboard port
is not another prompt; source/APT use port 80 and Homebrew uses 8080 unless you
set `dashboard.port` in `config.json`:

```text
Dashboard password (letters/numbers) [Enter = strong random]:
Nodes to run (comma-separated: bitcoin, monero, tari, litecoin, dogecoin, bitcoincash, zcash) [bitcoin]:
Dashboard bind address (loopback or private LAN) [127.0.0.1]:
One-click upgrades from the dashboard (Upgrade button)? [y/N]
Bitcoin data directory [./data/bitcoin]:
Expose Bitcoin RPC to trusted LAN wallet apps? [y/N]
Recent-block retention in GB [10]:
Download missing containers and start the stack now? [Y/n]
Generated credentials (shown once):
  Dashboard — username: admin  password: <dashboard password>
  Bitcoin RPC — username: admin  password: <different Bitcoin RPC password>
```

Package installation is deliberately noninteractive and does not start setup.
After installing a future Debian/APT package, run `sudo bitcoin-stack init`
explicitly. The project does not currently publish an APT feed.

Selecting Monero asks for its own data directory, optional restricted LAN RPC,
and optional LAN ZMQ for P2Pool. Selecting only Monero skips Bitcoin questions.
Every other selected chain asks for its data directory and optional private-LAN
RPC or gRPC listener. The wizard prints credentials only for selected nodes. See
[Pithead remote-node setup](nodes.md#pithead-remote-nodes).

Fresh APT and Homebrew wizard installs select `resource_profile: compact` for each
chosen node. The managed host helper waits for three spaced, healthy, current sync checks
before applying 1 CPU and 2048 MiB for Bitcoin/Monero or 4096 MiB for the other
nodes, with no extra swap. Homebrew performs the same checks through its
optional background service. Existing installs and
source installs leave automatic resource limits off. The profile remains
experimental until sustained capped operation is qualified; it is not a claim
that a whole 2 GiB VPS can host multiple nodes.

The wizard writes `steady_cpus: 1` and the chain-specific memory budget into
each selected node's `config.json` section. To change a budget, edit the
installation's `config.json` and run `bitcoin-stack apply` (`sudo` for APT).
Initial sync stays uncapped; the helper uses the edited values after its sync
checks pass. See [resource caps](configuration.md#resource-caps).

## First start: what to expect

1. **Tor bootstraps** (a minute or two):

   ```bash
   docker logs -f tor    # wait for "Bootstrapped 100% (done)"
   ```

2. **Bitcoin Core finds onion peers and syncs headers**, then blocks:

   ```bash
   docker logs -f bitcoin
   ```

3. **Monero**, if selected, starts a pruned sync through Tor. Its node status
   uses authenticated internal RPC; LAN clients use a separate restricted
   listener. An internal view-only wallet service supports dashboard monitoring;
   it has no host port and cannot spend. No miner starts.

4. **The dashboard** at `http://localhost` (or `http://localhost:8080` for
   Homebrew) shows the configured towers. Click a tower to
   open its chain's card. It shows a connecting state until RPC comes up,
   then sync progress. After its wallet section, that node's settings contain
   block alerts, LAN ports, and any authenticated RPC credentials. The gear
   menu contains global Appearance, Dashboard password, Telegram, and
   Healthchecks settings. A disabled node says **Not configured**.

To open it to your private LAN, set `dashboard.bind_ip` to this host's RFC1918
address and run `bitcoin-stack apply` or `./stack apply`. Wildcard and public
binds are rejected.

The node downloads and validates the whole historical chain, currently hundreds
of GB (roughly 900 GB), even though it later retains only 10,000 MiB of block files.
Over Tor, expect the first sync to take days. The dashboard remains informative
during sync. Container health is visible in `docker ps` — the selected
services define health checks, though `bitcoin` only reports healthy once
its RPC is warmed up.

## Verify it's working

```bash
./stack status        # source install
sudo bitcoin-stack status  # package install
bitcoin-stack status  # Homebrew install
```

If something looks wrong, see
[Operations → Troubleshooting](operations.md#troubleshooting).
