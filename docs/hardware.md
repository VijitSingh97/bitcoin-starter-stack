# Hardware Requirements

Reference deployment: a 4-core mini PC with 8 GB RAM and a 2 TB NVMe SSD
running Ubuntu Server 24.04. It syncs and serves the full chain
comfortably.

## Disk

The single number that matters most. As of mid-2026 the full chain is
**~800 GB** and grows roughly 50–100 GB per year.

- **Minimum:** 1 TB free — works today, forces a resize within a year or two.
- **Recommended:** 2 TB — years of headroom.
- **Pruned alternative:** ~30 GB total. Set `prune_mb` in `config.json`
  ([Configuration → Pruned node](configuration.md#pruned-node)) — full
  validation, a fraction of the disk, at the cost of not serving
  historical blocks.
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

Initial sync pulls ~800 GB through Tor. Steady state is a few GB per day.
No inbound host ports are needed — inbound arrives over the Tor onion service
(`inbound_onion`, on by default), never a forwarded port.
