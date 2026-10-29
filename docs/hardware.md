# Hardware Requirements

Reference deployment: a 4-core mini PC with 8 GB RAM and an NVMe SSD
running Ubuntu Server 24.04.

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

8 GB is comfortable. The main consumer is Bitcoin Core's UTXO cache,
controlled by `dbcache_mb` in `config.json` (default **3000**):

| System RAM | Suggested `dbcache_mb` |
|---|---|
| 4 GB | 1000 |
| 8 GB | 3000 (default) |
| 16 GB+ | 6000 — speeds up initial sync noticeably |

Larger is only better during initial block download and reindex; once
synced, steady-state usage is far lower. Don't set it near your total RAM —
Bitcoin Core needs overhead beyond the cache, and the OOM killer is not a
graceful shutdown.

## CPU

Anything 4-core from the last decade is fine. Signature validation
parallelizes across cores during initial sync; after that the node mostly
idles.

## Network

Initial sync still pulls the whole historical chain, currently roughly 900 GB,
through Tor and can take days. Steady state is a few GB per day. Bitcoin P2P
needs no inbound host port; the optional inbound onion service is disabled by
default. The dashboard binds port 80 to
loopback by default, or to an explicit private address for LAN access.
