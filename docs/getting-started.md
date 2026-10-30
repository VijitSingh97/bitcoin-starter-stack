# Getting Started

## Prerequisites

- **Ubuntu Server 24.04** (other Docker-capable Linux works, but this is
  what's tested).
- **[Docker Engine](https://docs.docker.com/engine/install/ubuntu/)** and
  Docker Compose **2.33.1 or newer**, with the
  [post-install steps](https://docs.docker.com/engine/install/linux-postinstall/)
  so your user can run `docker` without sudo.
- **`jq`, `openssl`, and `curl`** — configuration and downloads.
- Hardware per [Hardware Requirements](hardware.md) — the short version:
  allow 30–60 GB SSD space for Bitcoin and 120–150 GiB for Monero.
  The experimental steady budget is 1 CPU / 2 GiB per node, plus shared services
  and host overhead. Bitcoin has passed a short capped trial; sustained
  qualification for both daemons is pending. Initial sync is uncapped.
  For sync headroom, plan around 2 CPU cores and 4 GiB RAM per node; these are
  estimates, not minimum requirements or measured average usage. More resources
  can shorten validation; Tor and SSD performance also affect sync time.

Optional: after setting `dashboard.bind_ip` to this host's private address,
`avahi-daemon` lets you reach it at `http://<hostname>.local` from other
machines on your LAN.

Install `jq`, `openssl`, `curl`, and optionally `avahi-daemon` with APT.

## Install

The Ubuntu 24.04 APT package will become available with the next release, after
matching amd64 and arm64 dashboard images are published. It installs the
`bitcoin-stack` command globally and keeps mutable files in standard system
locations:

- configuration: `/etc/bitcoin-starter-stack/config.json`
- generated credentials and backups: `/var/lib/bitcoin-starter-stack/`
- Bitcoin chain data: `/var/lib/bitcoin-starter-stack/data/bitcoin/`
- Monero chain data: `/var/lib/bitcoin-starter-stack/data/monero/`

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

The wizard lets you select Bitcoin, Monero, or both, downloads missing images with the host's Docker
settings, and starts the stack when you accept its final default. Docker keeps
image layers in its own managed storage. Neither package installation nor the
wizard changes the Docker daemon or its proxy settings.

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
defaults (10 GB of recent blocks, about 30–60 GB total disk) and **auto-generates**
separate passwords for the dashboard and each node's RPC (username defaults to
`admin`). Existing generated credentials are retained on subsequent applies.

If you skip the wizard, read the generated dashboard login locally after first
start with `sed -n 's/^DASHBOARD_PASSWORD=/Password: /p' .env`; the username is
`admin`. The wizard instead prints its newly created login once at the end.

The `tor`, `dashboard`, and optional `monero` images are published prebuilt on GHCR
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

A default source-install wizard run includes these choices:

```text
Dashboard password (letters/numbers) [Enter = strong random]:
Nodes to run — bitcoin, monero (experimental), or both [bitcoin]:
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
The wizard prints credentials only for selected nodes. See
[Pithead remote-node setup](nodes.md#monero-as-a-remote-node-for-pithead).

Fresh package wizard installs select `resource_profile: compact` for each
chosen node. A host timer waits for three spaced, healthy, current sync checks
before applying 1 CPU and 2048 MiB, with no extra swap. Existing installs and
source installs leave automatic resource limits off. The profile remains
experimental until sustained capped operation is qualified; it is not a claim
that a whole 2 GB VPS can host multiple nodes.

The wizard writes `steady_cpus: 1` and `steady_mem_limit_mb: 2048` into each
selected node's `config.json` section. To change a budget, edit
`/etc/bitcoin-starter-stack/config.json` and run `sudo bitcoin-stack apply`.
Initial sync stays uncapped; the timer uses the edited values after its sync
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

4. **The dashboard** at `http://localhost` shows two towers. Click a tower to
   open its chain's card. It shows a connecting state until RPC comes up,
   then sync progress. A disabled node says **Not configured**.

To open it to your private LAN, set `dashboard.bind_ip` to this host's RFC1918
address and run `./stack apply`. Wildcard and public binds are rejected.

The node downloads and validates the whole historical chain, currently hundreds
of GB (roughly 900 GB), even though it later retains only 10 GB of block files.
Over Tor, expect the first sync to take days. The dashboard remains informative
during sync. Container health is visible in `docker ps` — the selected
services define health checks, though `bitcoin` only reports healthy once
its RPC is warmed up.

## Verify it's working

```bash
./stack status        # source install
sudo bitcoin-stack status  # package install
```

If something looks wrong, see
[Operations → Troubleshooting](operations.md#troubleshooting).
