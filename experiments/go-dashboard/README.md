# Go dashboard resource experiment

This experiment measures whether a read-only Go dashboard saves enough resources to justify replacing the released Python dashboard. It is not a deployment candidate.

The Go prototype renders the same node status UI and exposes the same read routes used by the dashboard: `/`, `/metrics`, `/api/fees`, `/api/watch`, static assets, and the disabled upgrade status. The benchmark intentionally excludes wallet and upgrade mutations. Both implementations make the same eight serial fake-RPC calls for each synced `/` and `/metrics` request. Background node and fee sampling stay enabled at their production intervals. This is parity for the read-only UI subset, not full feature parity with the production Python application.

The Python reference is the unmodified published `ghcr.io/vijitsingh97/bitcoin-starter-stack-dashboard:1.31.1` image. `python_reference.py` only supplies the fake RPC URL and disables the daily outbound release lookup. It still starts the real Waitress server, monitor, fee sampler, and inactive empty-wallet sampler.

The Go poller does not implement Python's alert transition state machine or event log. Python retains that work with notification delivery disabled. Go also polls network information every minute, whereas Python's monitor requests it for the daily update check. These differences remain in the measurement: it compares a read-only prototype with the released Python process and cannot establish language-only savings or the cost of a complete Go port.

## Safety boundary

`run-benchmark.sh` only runs on mini-1 from `/home/vijit/maintenance-20261027/go-dashboard-benchmark`. It reads `~/README.md`, requires production containers to be running, snapshots production container identities, image references, start times, mounts, checkout HEAD, current symlink, and a one-way `.env` hash, then compares the snapshot after the run.

The benchmark uses only `bss-go-bench-*` containers and the internal, egress-free `bss-go-bench-net`. Its fake RPC server accepts a read-only allowlist and separate `go`/`py` credentials. No container publishes a host port: the runner inspects each container's private IPv4 address on the benchmark network, verifies that it has no other network or default outbound route, and sends benchmark traffic directly to those private addresses. It never joins `btc_net`, mounts `.bitcoin`, uses real RPC credentials, exposes port 80, pulls or retags an image, prunes images, or stops a production container. Containers and the network carry a per-run ownership label; cleanup removes only matching labeled resources and refuses pre-existing names.

The runner verifies the exact staged file set and every file's digest against `MANIFEST.sha256`, rejects extra files, directories, and symlinks, and requires the separately reviewed manifest hash in `GO_BENCH_SOURCE_MANIFEST_SHA256`. It also requires the reviewed Go image ID in `GO_BENCH_IMAGE_ID`. The Python containers run by immutable image ID taken from the live dashboard after verifying that its configured reference is the released 1.31.1 image.

Each app is non-root with all capabilities dropped, `no-new-privileges`, a read-only root filesystem, 256 MiB memory, 0.5 CPU, and 64 PIDs. The fixture is capped at 128 MiB and 0.5 CPU.

## Method

After a 30-second warmup, three cycles run:

1. Both apps idle for 70 seconds.
2. Each app receives 30 seconds at a fixed two requests per second, alternating which app goes first each cycle.
3. The request mix rotates through `/`, `/metrics`, `/api/fees`, and `/api/watch` with Basic authentication and at most two concurrent requests.

The runner records cgroup-v2 current and peak memory, working set (`memory.current - inactive_file`), process RSS/HWM, threads, one-core CPU percentage, throttling, Docker-reported local disk footprint (containerd stores compressed and unpacked layers), response errors, p50/p95 latency, and fake-RPC counts. Results land in `results/report.json` and `results/requests.csv` under the private scratch directory.

This is a controlled short benchmark of roughly seven minutes. It is suitable for deciding whether the likely savings are meaningful on mini-1; it is not a long-duration capacity study or proof that language choice alone caused every measured difference.

## Local checks

```sh
python3 experiments/go-dashboard/selftest.py
bash -n experiments/go-dashboard/run-benchmark.sh
(cd experiments/go-dashboard && go test ./...)
docker build --platform linux/amd64 -f experiments/go-dashboard/Dockerfile -t bss-go-bench-go:local .
```

## Result

Measured on mini-1 on 2026-10-27, using source commit `524020b3676a92f8f427fc0d5528944c56b8dca9`: Ubuntu 24.04.5, kernel 6.8.0-147, Intel i5-4278U (two cores/four threads), and 7.63 GiB RAM. The run took approximately seven minutes.

| Measurement | Released Python 1.31.1 | Go prototype |
| --- | ---: | ---: |
| Idle RAM, working set | 33.33 MiB | 7.08 MiB |
| RAM at two requests/second, working set | 33.33 MiB | 7.27 MiB |
| Process RSS during traffic | 45.65 MiB | 14.88 MiB |
| Idle CPU, percent of one logical core | 0.0275% | 0.0084% |
| CPU at two requests/second, percent of one logical core | 2.54% | 1.27% |
| Response time, p50 | 11.85 ms | 5.81 ms |
| Response time, p95 | 34.41 ms | 14.78 ms |
| Uncompressed image layer tar bytes | 137.79 MiB | 9.55 MiB |

Memory figures are medians of each phase's sampled peak; CPU and latency figures are medians across the three cycles. Working set excludes inactive file cache. RSS includes resident mapped files and can count shared pages in multiple processes, so it is recorded separately. Image layer totals are calculated after decompression; raw Docker store figures in the report include backend-dependent storage overhead and are not used for the image comparison.

The prototype used 78% less working-set RAM under traffic, saving 26.06 MiB, and 50% less application CPU at this request rate. Its uncompressed image layers were 93% smaller. The RAM saving is about 0.33% of mini-1's installed memory. Both applications were almost idle without traffic, so a rewrite would make little practical difference to this single server's capacity.

All 360 measured HTTP requests succeeded, with zero CPU throttling and zero rejected RPCs. Each application's 180 measured requests required 720 foreground RPCs; the Go and Python totals were 724 and 726, respectively. The extra calls exactly match the minute-level node/fee samplers described above. Production container identities, start times, mounts, checkout, credentials hash, and `current` pointer were identical before and after. All benchmark containers and its network were removed. Bitcoin, Tor, and the released dashboard remained healthy; Bitcoin was fully synced at height 973466 with no warnings after cleanup.

The run supports keeping this as an experiment: porting wallet management, upgrades, notifications, and recovery behavior would need separate implementation and validation. It does not establish the resource use of that complete port.

Raw evidence: [report](../go-dashboard-results/mini-1-2026-10-27/report.json), [requests](../go-dashboard-results/mini-1-2026-10-27/requests.csv), [image provenance and sizes](../go-dashboard-results/mini-1-2026-10-27/image-evidence.json), [runtime isolation](../go-dashboard-results/mini-1-2026-10-27/runtime-evidence.json), and [completion checks](../go-dashboard-results/mini-1-2026-10-27/verification.json).

The Mac browser preview uses simulated node values. Its disk capacity/free-space values come from the Docker VM filesystem, not mini-1.
