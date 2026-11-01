<div align="center">

# Node Manager

### A lightweight dashboard for running and monitoring cryptocurrency nodes.

[![CI](https://github.com/VijitSingh97/node-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/VijitSingh97/node-manager/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/VijitSingh97/node-manager)](https://github.com/VijitSingh97/node-manager/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: Ubuntu and macOS](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20macOS-4B5563)
![Runtime: Tor-only](https://img.shields.io/badge/Runtime-Tor--only-7D4698?logo=torproject&logoColor=white)

Run Bitcoin, Monero, Tari, Litecoin, Dogecoin, Bitcoin Cash, and Zcash from one
small Go dashboard. Public runtime traffic stays behind Tor. The dashboard and
optional node interfaces stay on your trusted LAN.

<img src="./images/nodes.png" width="100%" alt="Node Manager in light mode with seven cryptocurrency node towers" />

<sub>Preview with sample data. Your dashboard reads your own nodes.</sub>

</div>

## Why Node Manager

- One lightweight dashboard for new or existing nodes.
- Pruned storage by default, with uncapped initial sync and configurable
  post-sync resource limits.
- Tor-only public egress for nodes, prices, alerts, and update checks.
- Private LAN dashboard with an optional password; node interfaces are closed
  until you enable them.
- View-only wallet monitoring where the node can support it. Node Manager never
  accepts a seed phrase or private spend key.
- Telegram alerts, Healthchecks.io, live sync progress, disk monitoring, and
  per-node controls.

Version 1.32.0 is the first multi-chain Node Manager release. The package and
command retain the names `bitcoin-starter-stack` and `bitcoin-stack` so existing
installations and data paths continue to work.

## Ubuntu install with APT

Requires Ubuntu 24.04, Docker Engine, and Docker Compose 2.33.1 or newer. Install
and start Docker using the [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/),
then verify it:

```bash
sudo docker info
sudo docker compose version
```

The commands verify the release signing key before adding the APT repository.

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

expected='72FD656754BD7534E274360A37070C2730C0B4EA'
printf '%s\n' "$expected" | grep -Eq '^[0-9A-Fa-f]{40}$' || {
  echo 'Set the published Node Manager APT signing fingerprint first.' >&2
  exit 1
}

key=$(mktemp)
trap 'rm -f "$key"' EXIT
curl --fail --show-error --silent \
  https://vijitsingh97.github.io/node-manager/bitcoin-starter-stack.asc \
  --output "$key"
listing=$(gpg --batch --show-keys --with-colons "$key") || {
  echo 'Unable to parse the APT signing key.' >&2
  exit 1
}
actual=$(awk -F: '
  $1 == "pub" { primary_keys++ }
  $1 == "fpr" && primary_fingerprint == "" { primary_fingerprint = $10 }
  END { print primary_keys ":" primary_fingerprint }
' <<<"$listing") || exit 1
[ "$actual" = "1:$expected" ] || {
  echo 'APT signing key does not contain exactly the expected primary key.' >&2
  exit 1
}

sudo install -m 0644 "$key" /usr/share/keyrings/bitcoin-starter-stack.asc
echo 'deb [signed-by=/usr/share/keyrings/bitcoin-starter-stack.asc] https://vijitsingh97.github.io/node-manager ./' |
  sudo tee /etc/apt/sources.list.d/bitcoin-starter-stack.list
sudo apt update
sudo apt install bitcoin-starter-stack
sudo bitcoin-stack init
```

`init` creates a private configuration, downloads the required container images,
starts a pruned Bitcoin node, and prints the dashboard URL. The package itself
does not start containers during installation.

Configuration: `/etc/bitcoin-starter-stack/config.json`<br>
State and chain data: `/var/lib/bitcoin-starter-stack/`

See the [getting-started guide](docs/getting-started.md) for custom storage,
first-boot configuration, upgrades, and package-feed trust details.

## macOS install with Homebrew

Install and start [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/),
then verify Docker Compose 2.33.1 or newer:

```bash
docker info
docker compose version
```

Install Node Manager and start the default node:

```bash
brew tap vijitsingh97/bitcoin-starter-stack https://github.com/VijitSingh97/node-manager.git
brew install vijitsingh97/bitcoin-starter-stack/bitcoin-starter-stack
bitcoin-stack init
```

The dashboard defaults to port `8080`. Setup chooses a private LAN address when
one is available and prints the exact URL.

Configuration: `~/Library/Application Support/bitcoin-starter-stack/config/config.json`<br>
State and chain data: `~/Library/Application Support/bitcoin-starter-stack/`

Enable **Launch at login** in Settings if the stack should return when you sign
in. Docker Desktop must also be running. See the [Homebrew guide](docs/homebrew.md)
for custom paths, services, upgrades, and removal.

## Safe defaults

A fresh `init` starts Bitcoin only with 10 GB of recent block files retained.
The dashboard has no password and is available only on the selected localhost or
private-LAN address. Every RPC, gRPC, and ZMQ interface is closed. Launch at
boot or login is off.

Use Node Manager only on a trusted LAN. Add a dashboard password in Settings,
and never forward the dashboard or a node interface to the public internet.
LAN HTTP and node RPC are unencrypted. Read the [privacy model](docs/privacy.md)
before enabling remote access.

Install more chains from **Settings → Node set**. Before downloading anything,
Node Manager shows the data path, estimated disk requirement, and optional LAN
interfaces. All interfaces remain closed unless you explicitly enable them.

## Hardware and storage

Use an SSD and start with one chain on smaller machines. Pruning reduces retained
storage; initial sync still downloads and validates the chain history.

Sync is uncapped by default. The experimental post-sync caps are **1 CPU / 2 GiB**
for Bitcoin and Monero and **1 CPU / 4 GiB** for the other nodes. Wallet services,
Tor, Docker, and your operating system need additional memory. These are editable
ceilings, not qualified minimum hardware.

See [per-node disk and resource estimates](docs/nodes.md) before adding chains.

## After installation

```bash
bitcoin-stack status
bitcoin-stack up
bitcoin-stack down
```

Use `sudo` with an APT installation. Configure nodes from the dashboard and see
[Operations](docs/operations.md) for backups, upgrades, logs, and troubleshooting.

## Documentation

- [Getting started](docs/getting-started.md)
- [Configuration reference](docs/configuration.md)
- [Node storage and resources](docs/nodes.md)
- [Watch-only wallets](docs/watch-only.md)
- [Notifications](docs/notifications.md)
- [Operations and upgrades](docs/operations.md)
- [Tor and security model](docs/privacy.md)
- [Contributing](CONTRIBUTING.md)

Node Manager is released under the [MIT License](LICENSE).
