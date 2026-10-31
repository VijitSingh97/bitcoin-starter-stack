# Supported nodes

Node Manager supports Bitcoin Core, Monero, Tari, Litecoin, Dogecoin,
Bitcoin Cash Node, and Zcash through Zakura. Select any non-empty combination in
setup. Each selected chain gets a separate data directory and resource profile.
RPC credentials are separate for each authenticated endpoint; the dashboard has
its own password.

The package and existing data paths retain the `bitcoin-starter-stack` name for
upgrade compatibility. Changing the product name does not move chain data.

## Storage and resource planning

Pruning limits retained history, but every node still downloads and validates
its chain. A block-retention setting does not include chainstate, indexes, logs,
temporary compaction space, or future growth.

| Node | Default retained history | Disk planning allowance | Sync budget | Post-sync compact budget | Qualification |
|---|---:|---:|---:|---:|---|
| Bitcoin Core | 10,000 MiB of block files | 30–60 GB total | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 2 GiB | Short capped trial passed; 24-hour qualification pending |
| Monero | Native pruned mode | 120–150 GiB; upstream reported about 105 GiB pruned on October 5, 2026 | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 2 GiB, plus its wallet service | Not yet qualified |
| Tari | 10,000-block pruning horizon | No current measured total; use an expandable volume and measure after first sync | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 4 GiB | Protocol and Tor startup proven; full sync not qualified |
| Litecoin | 10,000 MiB of block files | Provisional 30–60 GB; current full-sync total is not measured | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 4 GiB | Binary and runtime startup proven; full sync not qualified |
| Dogecoin | 10,000 MiB of block files | Provisional 30–60 GB; current full-sync total is not measured | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 4 GiB | Binary and runtime startup proven; full sync not qualified |
| Bitcoin Cash Node | 10,000 MiB of block files | Provisional 30–60 GB; current full-sync total is not measured | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 4 GiB | Signed upstream binary and runtime startup proven; full sync not qualified |
| Zcash / Zakura | Pruned state with 10,000 retained blocks | Upstream's published snapshot was roughly 11 GB when checked; plan 30–60 GB on an expandable volume until a full sync is measured | Uncapped; plan around 2 CPU / 4 GiB RAM | 1 CPU / 4 GiB | Pruning, Tor bootstrap, and RPC proven; full sync not qualified |

All six non-Bitcoin adapters have passed native-daemon startup and dashboard
checks on an Apple Silicon Mac using Docker Desktop. These checks cover Tor
routing and published endpoint access; they do not establish full-sync disk
usage or sustained operation within the compact budgets. Linux runs the same
checks separately for every chain in CI.

The Litecoin, Dogecoin, Bitcoin Cash, and Zcash figures are planning allowances,
not measured usage. Tari has no defensible total-size estimate yet, so do not put
it on a fixed small volume. The dashboard shows live chain and free-disk values;
record the final size after the first complete sync and leave growth headroom.

Monero's base figure comes from its
[official remote-node guide](https://docs.getmonero.org/interacting/remote-nodes/).
Tari pruning follows its
[syncing and seeding specification](https://rfc.tari.com/RFC-0140_Syncing_and_seeding).
Bitcoin-family pruning retains a configured amount of recent block files while
keeping the live chainstate.

Budgets apply **per node**. Bitcoin plus Monero in compact mode therefore needs
up to 4 GiB for the daemons. Three of the newer nodes need up to 12 GiB. Add
memory and CPU for Tor, the Go dashboard, Docker, filesystem cache, the operating
system, and Monero's optional wallet service. Sync one chain at a time on a small
host. A container cap on a larger test machine does not qualify a real VPS with
the same total RAM.

## Dashboard data

Panels share sync progress, block height, peers, disk space, resource profile,
endpoint status, and price fields. A value the native daemon cannot supply is
shown as unavailable rather than estimated or copied from another chain. Tari
does not report an uptime or fee estimate through its status API; a zero pruned
height leaves its pruning status unknown until pruning has occurred.

Fee estimates retain their native units: Litecoin uses litoshi/vB, Dogecoin uses
DOGE/kB, and Bitcoin Cash uses sat/B. Bitcoin Cash reports one general estimate;
Litecoin and Dogecoin report 1-, 3-, and 6-block targets when enough observations
are available. An insufficient-history response is shown as unavailable.
Zcash displays its standard ZIP-317 fee separately from an estimate.

Bitcoin watch-only wallets and Monero view-only wallets are supported. The other
chains currently provide node monitoring without a wallet view.

## Setup wizard

APT/deb installation does not start services or prompt during `apt install`.
Run `sudo bitcoin-stack init` afterward. Source installs use `./stack init`.
The wizard asks for:

1. A dashboard password and one or more chains.
2. The dashboard's loopback or private-LAN address.
3. A data directory for every selected node.
4. Optional private-LAN RPC or gRPC exposure for each node, disabled by default.
5. Bitcoin's recent-block budget and Monero's optional ZMQ endpoint.
6. Whether to download missing images and start now.

Fresh package wizard installs use the `compact` profile: sync is uncapped, then
the host timer waits for repeated healthy, current sync checks before applying
the table's per-node ceiling with no extra swap. Source installs and existing
profiles remain `off` unless configured. These are editable budgets, not claims
that every chain has passed sustained operation within them.

Package data defaults to `/var/lib/bitcoin-starter-stack/data/<node>`. Source
installs default to `./data/<node>`. Choose a mounted SSD path in the wizard when
the default disk is too small.

## Private-LAN endpoints

All node endpoints are off by default and accept only an IPv4 address assigned
to the host's private LAN. The host helper rejects public, wildcard, loopback,
malformed, conflicting, and already-used bindings before applying a change.

| Node | Default host port | Authentication and intended use |
|---|---:|---|
| Bitcoin Core | 8332 | Generated Bitcoin RPC login; trusted wallet apps |
| Monero restricted RPC | 18081 | Generated Digest-auth login; wallets and Pithead/P2Pool |
| Monero ZMQ | 18083 | No application authentication; trusted P2Pool host only |
| Tari gRPC | 18142 | No application authentication; Pithead remote Tari base node on trusted LAN/WireGuard |
| Litecoin | 9332 | Generated Litecoin RPC login |
| Dogecoin | 22555 | Generated Dogecoin RPC login |
| Bitcoin Cash Node | 8332 | Generated Bitcoin Cash RPC login |
| Zcash | 8232 | Generated login to the dashboard's authenticated read-only proxy; native Zakura RPC is never published |

The public P2P runtime stays behind Tor whether or not a LAN endpoint is
enabled. These LAN services are plaintext inside the trusted network. Never
forward them to the public internet.

## Pithead remote nodes

For Monero, enable restricted RPC and, when P2Pool needs it, ZMQ. Enter the
server's private address, the configured ports, and the **Monero RPC** login in
Pithead. The dashboard login is unrelated. ZMQ has no password.

For Tari, enable gRPC on port 18142 and configure Pithead with `tari.mode:
remote`, this host, and the gRPC port. Pithead's current mining client uses
plaintext unauthenticated gRPC, so use only a trusted LAN or WireGuard link.
The allowlist supports node status, mining-template creation, and block
submission. The stack runs no miner, wallet, or payout key.

Pithead's current settings are documented in its
[remote-node configuration](https://github.com/p2pool-starter-stack/pithead/blob/develop/docs/configuration.md#remote-tari-node).

## Deactivation

An authenticated dashboard user can deactivate one configured node. The host
helper gracefully stops only that daemon and its dependent wallet service,
keeps its data and configuration, and leaves its tower visible but inactive.
Activating it starts the same configured service again. At least one node must
remain configured; deactivation is different from deleting a chain or its data.
