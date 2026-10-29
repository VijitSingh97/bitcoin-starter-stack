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
  4 cores, 8 GB RAM, and 30–60 GB free on an SSD for the default pruned node.
  An archival node needs about 1 TB free today.

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

The wizard configures the node, downloads missing images with the host's Docker
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
the internal RPC password (username defaults to `admin`) shared by the dashboard
and bitcoind.

If you skip the wizard, read the generated dashboard login locally after first
start with `sed -n 's/^DASHBOARD_PASSWORD=/Password: /p' .env`; the username is
`admin`. The wizard instead prints its newly created login once at the end.

The `tor` and `dashboard` images are published prebuilt on GHCR
(`ghcr.io/vijitsingh97/bitcoin-starter-stack-*`) for amd64 and arm64
(Raspberry Pi). `./stack pull` downloads them with the host's existing Docker
settings. The running Bitcoin and dashboard containers remain isolated behind
Tor regardless of how their images were obtained.

Everything is optional. Two ways to customize:

- **`./stack init`** — an interactive wizard that asks for a shared RPC/dashboard
  password (Enter generates a strong one and prints it once at the end), the data
  directory, a loopback or private-LAN dashboard address, one-click upgrades,
  optional private-LAN wallet RPC, recent-block retention, and whether to download
  missing images and start. Every prompt has a default you accept by pressing Enter.
- Or edit `config.json` by hand (copy `config.example.json`) and run
  `./stack apply`. Stick to letters and numbers in any credentials you set.

The full key reference is in [Configuration](configuration.md).

A default source-install wizard run includes these choices:

```text
Shared RPC and dashboard password (letters/numbers) [Enter = strong random]:
Bitcoin data directory [./data/bitcoin]:
Dashboard bind address (loopback or private LAN) [127.0.0.1]:
One-click upgrades from the dashboard (Upgrade button)? [y/N]
Expose Bitcoin RPC to trusted LAN wallet apps? [y/N]
Recent-block retention in GB [10]:
Download missing containers and start the stack now? [Y/n]
Dashboard login (shown once):
  Username: admin
  Password: <the password you entered or the generated password>
```

Package installation is deliberately noninteractive and does not start setup.
After installing a future Debian/APT package, run `sudo bitcoin-stack init`
explicitly. The project does not currently publish an APT feed.

## First start: what to expect

1. **Tor bootstraps** (a minute or two):

   ```bash
   docker logs -f tor    # wait for "Bootstrapped 100% (done)"
   ```

2. **Bitcoin Core finds onion peers and syncs headers**, then blocks:

   ```bash
   docker logs -f bitcoin
   ```

3. **The dashboard** at `http://localhost` shows a holding page until
   the node's RPC comes up, then live sync progress.

To open it to your private LAN, set `dashboard.bind_ip` to this host's RFC1918
address and run `./stack apply`. Wildcard and public binds are rejected.

The node downloads and validates the whole historical chain, currently hundreds
of GB (roughly 900 GB), even though it later retains only 10 GB of block files.
Over Tor, expect the first sync to take days. The dashboard remains informative
during sync. Container health is visible in `docker ps` — all three
services define health checks, though `bitcoin` only reports healthy once
its RPC is warmed up.

## Verify it's working

```bash
./stack status        # source install
sudo bitcoin-stack status  # package install
```

If something looks wrong, see
[Operations → Troubleshooting](operations.md#troubleshooting).
