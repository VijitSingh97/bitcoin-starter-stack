# Hardware Requirements

Reference deployment: a 4-core mini PC with 8 GB RAM and an NVMe SSD
running Ubuntu Server 24.04.

For current deployment planning, use 2 CPU cores and 4 GB RAM as a comfortable
target. A 1 CPU/2 GB configuration is being evaluated; benchmark results are
still pending, so it is not yet a validated minimum.

## Disk

The default keeps 10 GB of recent block files after validating the whole chain.
That target does not include chainstate, indexes, wallet data, logs, or headroom.

- **Default pruned node:** plan for 30–60 GB total. The live chainstate is
  currently about 12 GB, in addition to the 10 GB block-retention target.
- **Archival node:** roughly 900 GB today; 1 TB is tight and 2 TB provides
  practical growth room. Enable it manually with `prune_mb: 0`.
- **SSD required.** Chainstate access is random-I/O heavy; initial sync on a
  spinning disk takes weeks instead of days.

The dashboard shows chain size vs. disk capacity so you can watch the
headroom shrink.

## RAM

Fresh installs use a conservative **128 MiB** Bitcoin Core UTXO cache, controlled
by `dbcache_mb` in `config.json`. Existing installs keep their configured or
previously rendered value. Larger caches are optional tuning that can speed up
initial sync and reindexing:

| System RAM | `dbcache_mb` guidance |
|---|---|
| 2 GB evaluation target | Keep the 128 MiB default while evaluation is in progress. |
| 4 GB comfortable target | Start with 128 MiB; raise it only if faster initial sync is worth the extra memory. |
| 8 GB reference host | 128 MiB remains the default; 3000 MiB is an optional initial-sync tuning value. |
| 16 GB+ | Larger values such as 6000 MiB are optional initial-sync tuning. |

Don't set the cache near total RAM. Bitcoin Core also uses memory outside the
UTXO cache, and usage varies by workload; leave room for Tor, the dashboard,
Docker, and the host operating system. The OOM killer is not a graceful
shutdown.

## CPU

Two CPU cores are the comfortable planning target. One CPU is under evaluation
and is not yet a validated minimum. Signature validation parallelizes across
cores during initial sync; after that the node mostly idles.

## Network

Initial sync still pulls the whole historical chain, currently roughly 900 GB,
through Tor and can take days. Steady state is a few GB per day. Bitcoin P2P
needs no inbound host port; the optional inbound onion service is disabled by
default. The dashboard binds port 80 to
loopback by default, or to an explicit private address for LAN access.
