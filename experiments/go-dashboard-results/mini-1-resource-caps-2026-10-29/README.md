# mini-1 resource-cap trial

This trial exercised the production Go stack from commit `e636de6` with Bitcoin
Core 32.1 on the mini-1 host: Ubuntu Server 24.04.5, 4 logical CPUs (2 physical
cores), 8 GB RAM, and NVMe storage. Docker CPU quotas and memory limits bounded
the three application containers to two candidate host budgets.

## Method

- Each profile ran through a 120-second warmup before sampling.
- Samples checked container resources and health while Bitcoin Core continued
  initial block download.
- RPC and HTTP probes exercised the running stack during each sample window.
- CPU and memory budgets below include Bitcoin Core, Tor, and the dashboard.
  Temporary seed and Sitewatch containers were outside the measured budget.

| Profile | Bitcoin Core | Tor | Dashboard | Sample | Samples | RPC | HTTP failures | Block progress | Swap/OOM/restarts |
|---|---|---|---|---:|---:|---:|---:|---:|---|
| 2 CPU/4 GB | 0.5 CPU, 2500 MiB, `dbcache=512` | 0.75 CPU, 256 MiB | 0.75 CPU, 128 MiB | 300 s | 26 | 9/9 | 0 | +566 (490880→491446) | none |
| 1 CPU/2 GB | 0.5 CPU, 1152 MiB, `dbcache=128` | 0.25 CPU, 192 MiB | 0.25 CPU, 128 MiB | 600 s | 43 | 15/15 | 0 | +1200 (491703→492903) | none |

The absence of swap, OOM kills, and restarts applies to the three application
containers during these sample windows. The stack was tested on the 8 GB host
under container caps, not inside a 2 GB or 4 GB virtual machine. This trial does
not qualify a full initial sync, sustained full mempool, wallet-scan load, or
long-term operation. The memory limits were experimental constraints and are
not recommended permanent `mem_limit_mb` values.

Bitcoin Core's
[memory-reduction guide for v32.1](https://github.com/bitcoin/bitcoin/blob/v32.1/doc/reduce-memory.md)
provides upstream context for `dbcache` and other memory controls.
