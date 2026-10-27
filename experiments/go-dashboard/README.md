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
go test ./...
```

## Result

Pending the reviewed mini-1 run. The final comparison will report absolute resource use, savings relative to the full released Python image, throttling, request errors, and RPC-count parity.
