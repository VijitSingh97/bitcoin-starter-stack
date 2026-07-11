# Security Policy

## Reporting

Report vulnerabilities privately via
[GitHub Security Advisories](https://github.com/VijitSingh97/bitcoin-starter-stack/security/advisories/new).
Please don't open public issues for security problems.

## Threat model (what this stack does and doesn't protect)

**Protects:**

- **Your IP from the Bitcoin network.** All P2P traffic is outbound-only
  through Tor (`onlynet=onion`, `listen=0`, `proxy=` to the tor container).
  No clearnet P2P connections are ever made.
- **RPC from the outside.** Bitcoin Core's RPC port is never published to
  the host; it is reachable only from containers on the internal Docker
  network (`rpcallowip=172.16.0.0/12`).
- **Credentials from git.** RPC credentials live only in gitignored files —
  `config.json` and the rendered `.env` (mode 600) — and are never written
  into tracked files.

**Accepted risks (by design — know them before deploying):**

- **The dashboard has no authentication** and is published on host port
  `8000`. It is read-only status information, but it fingerprints the host
  as a Bitcoin node. Keep it on your LAN; never port-forward it.
- **Anyone with Docker access on the host can read the RPC credentials**
  (`docker inspect` shows container environment and command lines). Docker
  access is root-equivalent on the host anyway, so this is not treated as a
  boundary.
- **Initial block download trusts Tor exit-independent onion peers** but is
  still subject to the usual eclipse-attack tradeoffs of an outbound-only
  node with a small peer count.
