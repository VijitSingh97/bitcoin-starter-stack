# Security Policy

## Reporting

Report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/VijitSingh97/bitcoin-starter-stack/security/advisories/new).
Please don't open public issues for security problems.

## Threat model (what this stack does and doesn't protect)

**Protects:**

- **Your IP from the Bitcoin network.** All P2P traffic goes through Tor
  (`onlynet=onion`, `proxy=` to the tor container). No clearnet P2P
  connections are ever made. Inbound is accepted over a Tor onion service by
  default (`inbound_onion`) — it serves blocks to the network without exposing
  your IP or opening a host port; set it `false` to run outbound-only.
- **RPC from the outside.** Bitcoin Core's RPC port is never published to
  the host; it is reachable only from containers on the internal Docker
  network (`rpcallowip=172.16.0.0/12`).
- **Credentials from git.** RPC credentials live only in gitignored files —
  `config.json` and the rendered `.env` (mode 600) — and are never written
  into tracked files.
- **Your IP from notification services.** Opt-in Telegram alerts and
  Healthchecks.io pings route through the stack's Tor proxy (`socks5h`),
  so those endpoints see a Tor exit, never your address. (The Telegram bot
  token in `.env`/dashboard env can send messages as your bot if leaked —
  it cannot read other chats or control the node.)
- **The plaintext RPC password from the bitcoin container.** bitcoind gets
  only a salted HMAC (`rpcauth`); `docker inspect bitcoin` reveals no
  password. The plaintext exists in the dashboard's environment (it must
  authenticate) and in `.env`. Its own health check uses Bitcoin Core's
  cookie file, not the password.

**Accepted risks (by design — know them before deploying):**

- **The dashboard defaults to no authentication** on host port `80`. It
  is read-only status information, but it fingerprints the host as a
  Bitcoin node. Keep it on your LAN and never port-forward it — or set
  `dashboard.password` in `config.json` to require HTTP basic auth (note:
  basic auth over plain HTTP is only as private as your LAN).
- **Anyone with Docker access on the host can read the dashboard's RPC
  password** via `docker inspect dashboard`. Docker access is
  root-equivalent on the host anyway, so this is not treated as a boundary.
- **Initial block download trusts onion peers** and is subject to the usual
  eclipse-attack tradeoffs of a Tor-only node with a small peer count.
