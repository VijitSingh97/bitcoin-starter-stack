# Getting Started

## Prerequisites

- **An existing Tor connection or an offline source/image bundle.** Set up
  [Tor for downloads](privacy.md#bootstrap-and-apt) before installing dependencies,
  cloning the repository, or fetching images. There is no clearnet bootstrap.
- **Ubuntu Server 24.04** (other Docker-capable Linux works, but this is
  what's tested).
- **[Docker Engine](https://docs.docker.com/engine/install/ubuntu/)** and
  Docker Compose **2.33.1 or newer**, with the
  [post-install steps](https://docs.docker.com/engine/install/linux-postinstall/)
  so your user can run `docker` without sudo.
- **`jq`, `openssl`, and `curl`** — configuration and verified Tor downloads.
- Hardware per [Hardware Requirements](hardware.md) — the short version:
  4 cores, 8 GB RAM, and 30–60 GB free on an SSD for the default pruned node.
  An archival node needs about 1 TB free today.

Optional: after setting `dashboard.bind_ip` to this host's private address,
`avahi-daemon` lets you reach it at `http://<hostname>.local` from other
machines on your LAN.

Once APT's Tor proxy is configured as described in the privacy guide, install
`jq`, `openssl`, `curl`, and optionally `avahi-daemon` through that proxy.

## Install

```bash
NO_PROXY='' no_proxy='' git -c http.proxy=socks5h://127.0.0.1:9050 clone \
  https://github.com/VijitSingh97/bitcoin-starter-stack.git
cd bitcoin-starter-stack
./stack up tor       # initial Tor image must already be loaded locally
./stack pull         # Docker's Tor proxy must be configured and active
./stack up
```

The clone example uses an existing Tor proxy on localhost. For an offline
installation, unpack the source and load the images locally instead. Follow the
[bootstrap guide](privacy.md#bootstrap-and-apt) for the initial image and Docker
proxy setup before running these commands. `up` and `apply` never download or
build implicitly.

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
(Raspberry Pi). `./stack pull` downloads them only after verifying the Docker
daemon's Tor proxy. Development builds require a separately Tor-routed build
environment.

Everything is optional. Two ways to customize:

- **`./stack init`** — an interactive wizard that asks for a shared RPC/dashboard
  password (Enter generates a strong one and prints it once at the end), the data
  directory, a loopback or private-LAN dashboard address, one-click upgrades,
  optional private-LAN wallet RPC, and recent-block retention. Every prompt has a
  default you accept by pressing Enter.
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
docker ps            # all three containers Up, eventually (healthy)
curl -s localhost | grep -o 'Bitcoin Node' | head -1
```

If something looks wrong, see
[Operations → Troubleshooting](operations.md#troubleshooting).
