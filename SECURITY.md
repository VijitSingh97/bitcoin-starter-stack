# Security Policy

## Reporting

Report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/VijitSingh97/node-manager/security/advisories/new).
Please don't open public issues for security problems.

## Threat model (what this stack does and doesn't protect)

**Protects:**

- **Your IP from the Bitcoin network.** All P2P traffic goes through Tor
  (`onlynet=onion`, `proxy=` to the tor container). No clearnet P2P
  connections are ever made. Inbound onion service is opt-in (`inbound_onion`), disabled by default.
  Enabling it serves peers without publishing a host P2P port.
- **RPC from the outside.** Node RPC ports remain internal by default. Optional LAN
  relays bind only to private host addresses; authenticated interfaces retain
  separate generated node credentials. Public and wildcard binds are rejected.
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

- **The dashboard defaults to no authentication on the trusted LAN.** It selects
  a private host IPv4 address, falling back to loopback. Homebrew uses port 8080;
  APT/source use port 80. LAN clients can view wallet information and saved
  notification values, install or deactivate nodes, and change settings. Add a
  dashboard password in Settings or preset it in configuration to restrict
  access. Passwordless mutations require local/private clients, trusted Host,
  and same-origin checks. Public/wildcard binds are rejected. Never port-forward
  the dashboard; basic auth over HTTP is still unencrypted. Credential
  reveal/reset and onion publication require a dashboard password.
- **Anyone with Docker access on the host can read the dashboard's RPC
  password** via `docker inspect dashboard`. Docker access is
  root-equivalent on the host anyway, so this is not treated as a boundary.
- **Initial block download trusts onion peers** and is subject to the usual
  eclipse-attack tradeoffs of a Tor-only node with a small peer count.
