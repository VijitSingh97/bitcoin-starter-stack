# Nodes and planned chains

Node Starter Stack currently implements Bitcoin Core and Monero. Choose one
or both in setup. Each node gets its own data directory and RPC password;
the dashboard has a third password. Existing Bitcoin installations keep their
credentials and storage paths when upgraded.

The GitHub repository, Debian package (`bitcoin-starter-stack`), command
(`bitcoin-stack`), container names, and existing Docker volumes retain their
names for upgrade compatibility. The new product name does not move your data.

## Storage and resource planning

| Node | Pruned storage | Current support | 1 CPU / 2 GiB per-node target |
|---|---|---|---|
| Bitcoin Core | Allow 30–60 GB total with the default 10 GB block-retention budget. Chainstate is additional to that budget. | Node status, public-only watch balances, fees, BTC prices, notifications, optional LAN RPC. | Short capped trial passed; full post-sync stability qualification is pending. |
| Monero | Official documentation reports about 105 GiB pruned as of October 5, 2026. Allow 120–150 GiB for growth and working room. | Node status, native fees, XMR prices, view-only balances, optional restricted LAN RPC and LAN ZMQ for Pithead/P2Pool. | Experimental until a sustained capped test passes. |

Monero's base figure comes from its [official remote-node guide](https://docs.getmonero.org/interacting/remote-nodes/).
The extra room above is our planning allowance, not an upstream minimum.
Disk use grows; pruning does not make chainstate a fixed size.

The resource budget applies **to each node**, not to the whole machine. Two
nodes therefore need room for 4 GiB of node memory, plus Tor, the dashboard,
Docker, filesystem cache, and the operating system. A container limit on an
8 GB test host does not prove identical behavior on a 2 GB VPS.

Initial sync can use all available CPU and memory. Both nodes still download
and validate historical data; pruning reduces retained disk data, not the
validation work. Tor throughput, disk latency, CPU, and starting height make
sync times vary from hours to days or longer. Temperature protection remains
the host operator's responsibility; unlimited containers cannot override it.
For initial sync, budget around 2 CPU cores and 4 GiB RAM per node as a planning
estimate, not a fixed minimum. See [sync versus normal operation](hardware.md#sync-versus-normal-operation)
for estimates, measured evidence, and shared-service overhead.

## Wizard

APT/deb installation does not run an interactive prompt or start services.
Run `sudo bitcoin-stack init` after installing. Source installs use `./stack init`.

Setup asks which implemented nodes to run and then asks only about those nodes:

1. Dashboard password.
2. Bitcoin, Monero, or both, and a loopback/private-LAN dashboard address.
3. Each selected node's data directory.
4. Optional LAN RPC, independently for each node; disabled by default.
5. Bitcoin's recent-block budget, or Monero's default pruned mode.
6. Optional Monero ZMQ for a trusted LAN P2Pool host; disabled by default.
7. Download missing images and start now, or save configuration for later.

The wizard generates independent RPC passwords and prints selected services'
credentials at the end. Save them privately. Package data defaults to
`/var/lib/bitcoin-starter-stack/data/bitcoin` and
`/var/lib/bitcoin-starter-stack/data/monero`. Source installs default to
`./data/bitcoin` and `./data/monero`. You can choose a mounted SSD instead;
the paths shown by the wizard are the paths it will actually use.

Fresh package wizard installs select the experimental `compact` profile for
each selected node: unlimited sync, then a host timer qualifies three healthy,
current sync checks before applying 1 CPU and 2048 MiB with no extra swap.
Those defaults are saved as `steady_cpus` and `steady_mem_limit_mb` in each
selected node's config section; edit them and run `sudo bitcoin-stack apply`
to change the budget. Initial sync stays uncapped.
Existing and source installs leave this off. The timer preserves explicit
operator limits and refuses an unsafe handoff when memory stays too high.
It requalifies recreated containers; an application upgrade can briefly return
them to uncapped operation. Check `journalctl -u bitcoin-starter-stack-resource-profile`
for a blocked handoff. See [configuration](configuration.md) for disabling it.

Dashboard onion access and inbound Bitcoin onion connections remain advanced
configuration options, both off by default. Runtime public traffic uses Tor
even when those inbound services are disabled. APT and container-image downloads
use the host's networking, as explained in [Privacy](privacy.md).

## Monero as a remote node for Pithead

Enable restricted Monero RPC on your server's private IPv4 address. Its default
port is **18081**. In Pithead, choose a remote Monero node and enter this host,
port, and the generated **Monero RPC** username/password, not the dashboard login.
The daemon uses Digest authentication. RPC is HTTP on a trusted LAN; do not
forward it to the public internet.

For P2Pool, also enable the Monero ZMQ publisher, default port **18083**, on a
trusted LAN. ZMQ has no password: only enable it where every host on the
network is trusted. It is an independent opt-in, not a side effect of enabling
RPC. The dashboard uses a separate authenticated internal RPC listener for
complete uptime, version, and pruning status; restricted RPC redacts those
fields. That internal listener is never published or relayed to the LAN.

This follows Pithead's [remote-node settings](https://github.com/p2pool-starter-stack/pithead/blob/develop/docs/configuration.md)
and [Monero configuration](https://github.com/p2pool-starter-stack/pithead/blob/develop/build/monero/bitmonero.conf.template).
P2Pool needs mining-template/submission RPC and ZMQ notifications; restricted
Monero RPC supports the relevant methods. No miner or Tari merge-mining proxy
is started by this stack.

The dashboard also runs an internal, authenticated wallet service for Monero
view-only monitoring. It accepts a primary mainnet address and private view key,
never a private spend key or seed. The service has no host port and stores
encrypted watch-only wallet files in its own private Docker volume. See
[Watch-only balances](watch-only.md#monero-view-only-wallets) and Monero's
[official view-only guide](https://www.getmonero.org/resources/user-guides/view_only.html).

## Other chains evaluated

These are candidates, not selectable or downloadable adapters. Findings were
checked against upstream sources on October 30, 2026. None has passed this
stack's Tor isolation, upgrade, pruning, and capped stability tests yet.

| Chain / daemon | Fit for this design | What remains before enabling it |
|---|---|---|
| [Litecoin Core](https://github.com/litecoin-project/litecoin/blob/master/doc/README.md) | Closest next adapter: Bitcoin-like JSON-RPC, pruning, and [Tor support](https://github.com/litecoin-project/litecoin/blob/master/doc/tor.md). | Pin verified images/binaries, test wallet/RPC differences, measure current disk use and 1 CPU / 2 GiB steady operation. Old upstream disk estimates are not current sizing guidance. |
| [Dogecoin Core](https://github.com/dogecoin/dogecoin/blob/master/doc/getting-started.md) | Pruning and [Tor proxying](https://github.com/dogecoin/dogecoin/blob/master/doc/tor.md) are available. | Verify discovery cannot leak DNS, test chain-specific sync/fee behavior, and measure disk/RAM. No current 2 GiB qualification. |
| [Tari / Minotari](https://github.com/tari-project/tari/blob/development/docs/guide/applications_overview.md) | Configurable pruning horizon and SOCKS transport; a different gRPC adapter is needed. | Explicit pruning (upstream horizon defaults to zero), fail-closed Tor testing, authenticated remote API design, and fresh disk/RAM benchmarks. No verified 2 GiB floor. |
| [Zcash / Zebra](https://github.com/ZcashFoundation/zebra) | Does not currently meet our pruned-only profile. | Upstream historical block-body [pruning remains open](https://github.com/ZcashFoundation/zebra/issues/12071). Revisit after it ships; resource and Tor-isolation testing would still be required. |
| [Bitcoin Cash Node](https://github.com/bitcoin-cash-node/bitcoin-cash-node/blob/master/doc/README.md) | Another Bitcoin-family candidate with pruning and [Tor support](https://github.com/bitcoin-cash-node/bitcoin-cash-node/blob/master/doc/tor.md). | Same packaging, isolation, RPC, storage, and stability checks as Litecoin. |

The recommended order is Litecoin, Dogecoin, then Bitcoin Cash Node. Tari is a
separate adapter and resource experiment. Zcash waits for pruning. New chains
should appear in the wizard only after their complete install-and-monitor path
works; a checkbox must not imply a resource guarantee we have not measured.
