# Getting Started

## Prerequisites

- **Ubuntu Server 24.04** (other Docker-capable Linux works, but this is
  what's tested).
- **[Docker Engine](https://docs.docker.com/engine/install/ubuntu/)** with the
  [post-install steps](https://docs.docker.com/engine/install/linux-postinstall/)
  so your user can run `docker` without sudo.
- **`jq`** — used by `configure.sh` to read `config.json`.
- Hardware per [Hardware Requirements](hardware.md) — the short version:
  4 cores, 8 GB RAM, and ~1 TB free on an SSD.

Optional: `avahi-daemon` lets you reach the dashboard at
`http://<hostname>.local:8000` from other machines on your LAN.

```bash
sudo apt install jq avahi-daemon
```

## Install

```bash
git clone https://github.com/VijitSingh97/bitcoin-starter-stack.git
cd bitcoin-starter-stack
nano config.json    # set node_username and node_password
./configure.sh
docker compose up -d
```

`configure.sh` renders your settings into a gitignored `.env` and creates
the data directory. Stick to letters and numbers in the credentials — they
pass through shell and env-file layers where special characters can bite.
The full key reference is in [Configuration](configuration.md).

## First start: what to expect

1. **Tor bootstraps** (a minute or two):

   ```bash
   docker logs -f tor    # wait for "Bootstrapped 100% (done)"
   ```

2. **Bitcoin Core finds onion peers and syncs headers**, then blocks:

   ```bash
   docker logs -f bitcoin
   ```

3. **The dashboard** at `http://localhost:8000` shows a holding page until
   the node's RPC comes up, then live sync progress.

The initial block download is ~800 GB **over Tor** — expect it to take
days, not hours. The node is usable (and the dashboard informative) the
whole time. Container health is visible in `docker ps` — all three
services define health checks, though `bitcoin` only reports healthy once
its RPC is warmed up.

## Verify it's working

```bash
docker ps            # all three containers Up, eventually (healthy)
curl -s localhost:8000 | grep -o 'Bitcoin Node' | head -1
```

If something looks wrong, see
[Operations → Troubleshooting](operations.md#troubleshooting).
