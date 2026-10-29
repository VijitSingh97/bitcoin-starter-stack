# Hardware Requirements

Reference deployment and test host: a mini PC with 4 logical CPUs (2 physical
cores), 8 GB RAM, and an NVMe SSD running Ubuntu Server 24.04.5.

For deployment planning, use 2 CPUs and 4 GB RAM as the recommended target. A
short container-capped trial supports 1 CPU/2 GB as a small-host target: during
a 10-minute sample after warmup, the stack advanced 1,200 blocks with 15/15 RPC
checks succeeding, no HTTP failures, and no application-container swap, OOM
kills, or restarts. This trial did not cover a full initial sync, sustained full
mempool, or wallet-scan load. See the
[resource-cap experiment](../experiments/go-dashboard-results/mini-1-resource-caps-2026-10-29/README.md)
for the method, exact temporary caps, and the 2 CPU/4 GB profile results.

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
| 2 GB small-host target | Use 128 MiB. Existing users moving to 2 GB must set `bitcoin.dbcache_mb` to `128` explicitly because upgrades preserve older, larger cache settings. |
| 4 GB recommended target | Start with 128 MiB; raise it only if faster initial sync is worth the extra memory. |
| 8 GB reference host | 128 MiB remains the default; 3000 MiB is an optional initial-sync tuning value. |
| 16 GB+ | Larger values such as 6000 MiB are optional initial-sync tuning. |

Don't set the cache near total RAM. Bitcoin Core also uses memory outside the
UTXO cache, and usage varies by workload; leave room for Tor, the dashboard,
Docker, and the host operating system. The OOM killer is not a graceful
shutdown. Bitcoin Core's pinned
[memory-reduction guide](https://github.com/bitcoin/bitcoin/blob/v32.1/doc/reduce-memory.md)
explains the cache tradeoff and other memory controls. The optional container
memory cap remains disabled by default; the experiment's temporary caps are
measurements, not deployment recommendations.

## CPU

Two CPUs are the recommended planning target. The short capped trial supports
one CPU for a small host within the scope described above. Signature validation
parallelizes across CPUs during initial sync; after that the node mostly idles.

## Network

Initial sync still pulls the whole historical chain, currently roughly 900 GB,
through Tor and can take days. Steady state is a few GB per day. Bitcoin P2P
needs no inbound host port; the optional inbound onion service is disabled by
default. The dashboard binds port 80 to
loopback by default, or to an explicit private address for LAN access.
