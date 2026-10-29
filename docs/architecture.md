# Architecture

Three containers share the internal `btc_net` bridge (`172.29.0.0/24`). Only
Tor also joins the external `tor_egress` bridge.

```mermaid
flowchart LR
    You(["👤 You · Browser"])
    Net(["🌐 Tor Network"])

    subgraph stack ["🐳 bitcoin-starter-stack"]
      subgraph internal ["btc_net · internal · 172.29.0.0/24"]
        Dashboard["📊 dashboard<br/>.27 · Go"]
        Bitcoin["🟠 bitcoin<br/>.26 · Bitcoin Core"]
        Tor["🧅 tor<br/>.25 · SOCKS5"]
      end
    end

    You ==>|"HTTP :80 · loopback or private LAN"| Tor
    Tor ==>|"fixed TCP forward · :8000"| Dashboard
    You -.->|"optional authenticated RPC · private LAN"| Tor
    Tor -.->|"fixed TCP relay · :8332"| Bitcoin
    Dashboard -.->|"RPC :8332 (internal)"| Bitcoin
    Bitcoin ==>|"SOCKS5 :9050 (internal)"| Tor
    Tor <==> Net
```

## The services

| Service | Image | Runs as | Role |
|---|---|---|---|
| `tor` | `alpine:3.24` + tor (built locally) | `tor` user | Outbound SOCKS5 proxy at `172.29.0.25:9050`. Fresh onion identity per volume. |
| `bitcoin` | [`bitcoin/bitcoin`](https://hub.docker.com/r/bitcoin/bitcoin) (official, digest-pinned) | `1000:1000` | Full or pruned node. `-datadir=/data` bind-mounted from the host. Credentials, `dbcache`, and `prune` injected from `.env` at runtime. |
| `dashboard` | `alpine:3.24` + a static Go binary (built locally) | `1000:1000` | Polls the node over RPC every page load; reads the data dir read-only for disk stats. |

Static IPs keep the bitcoin entrypoint's `-proxy=` argument (in
`docker-compose.yml`) and the dashboard's RPC URL simple and deterministic.
Docker Compose 2.33.1 or newer is required for the gateway-priority setting
that makes `tor_egress` Tor's deterministic default route.

## Privacy model

- **`-onlynet=onion` + `-proxy=…`**, set by the bitcoin entrypoint in
  [docker-compose.yml](../docker-compose.yml), plus **`listen=0`** in
  [bitcoin.conf](../build/bitcoin/bitcoin.conf): every P2P connection is
  routed to onion peers through the Tor container. The node never dials
  clearnet; inbound peers use the optional onion service, disabled by default.
- **The application network is internal.** Bitcoin and dashboard have no
  external route and use loopback-only DNS, so a proxy bug fails closed.
  Tor alone joins `tor_egress`; its gateway has explicit priority. The host
  dashboard and optional LAN RPC ports terminate in Tor's container and forward
  only to fixed internal addresses.
- **Inbound onion service** (`inbound_onion` in `config.json`, opt-in):
  bitcoind registers an onion address over tor's cookie-authed control
  port and serves blocks to the network — still no clearnet, no host port,
  no IP exposure. The tor data volume is mounted read-only into the
  bitcoin container (whose process joins tor's group) so it can read the
  control-auth cookie.
- **RPC auth is a salted hash.** bitcoind is started with `rpcauth=`; the
  plaintext password exists only in the dashboard container and `.env`.
  The bitcoin health check authenticates with Core's `.cookie` file.
- **The only published port by default is the dashboard's `80`.** It binds to
  `127.0.0.1` by default; `dashboard.bind_ip` accepts only loopback or RFC1918
  host addresses for intentional LAN access. `bitcoin.rpc_expose` can publish
  authenticated RPC on a private host address through Tor's TCP relay;
  `rpcallowip` still restricts Core to Docker's address space. SOCKS (`9050`)
  and the Tor control port (`9051`) are not published to the host. The optional
  dashboard onion service adds reachability through Tor without another host port.
- **Notification egress rides Tor too.** Telegram messages and
  Healthchecks.io pings (both opt-in) go through the tor container's SOCKS
  proxy (`socks5h`, so even DNS resolves through Tor) — enabling alerts
  never turns the stack into a clearnet beacon.
- **BTC prices use the same Tor proxy.** A background CoinGecko request every five
  minutes caches nine fiat quotes; page loads and currency changes only read the
  cache. DNS resolves through Tor, TLS is verified, and failures never fall back to
  a direct connection. Quotes become stale after a failed fetch or fifteen minutes.

## Trust boundaries — and non-boundaries

- Fresh installs share one generated RPC/dashboard password. Existing deployments
  may keep an empty or separate `dashboard.password`. The default host bind is loopback; set a private
  `dashboard.bind_ip` to make LAN exposure intentional. See
  [SECURITY.md](../SECURITY.md).
  Personal wallet views and all wallet/upgrade mutations require a configured
  password; the exact public example is readable without one.
- The opt-in Upgrade button keeps the container↔host boundary intact: the
  dashboard writes a fixed marker file to its own volume — content never read,
  no Docker socket, no host access — and the host-side `upgrade-agent` polls
  for the marker and runs the same predetermined `./stack upgrade` you would.
  Even with a stolen dashboard password, the only possible action is
  "upgrade to the latest release" ([Upgrade button](operations.md#upgrade-button-opt-in)).
- Docker host access is **not** a boundary: `docker inspect` reveals RPC
  credentials. Anyone who can run Docker commands owns the box anyway.

## Startup behavior

The bitcoin entrypoint deletes stale `*.lock`/`LOCK` files before starting
bitcoind — recovery from hard power-offs, safe because `container_name`
guarantees a single instance. `stop_grace_period: 5m` gives Bitcoin Core
time to flush its cache on shutdown; don't `docker kill` it.
