# mini-1 full Go dashboard benchmark

This run compared the production Python dashboard with the full Go dashboard built from commit `14ce5ba30c7d9a68ec9ea356bafb964ad544c531`. The tested image was imported from `bss-go-preview-14ce5ba.tar` with archive SHA-256 `3950cd501a7965d7b8b3355ef538f5c949c40b6f60a0f06101b0d4b2fa13205a`; its source-side image ID was `sha256:243e3adc81fb9cf45ad8744d1906f3aef7bd301dc7d21614d140a8b39dd8ba93`.

## Method

- Hardware: the same mini-1 host for both dashboards.
- Warmup: 30 seconds.
- Repetitions: three cycles.
- Each cycle: 70 seconds idle, then 30 seconds of load against each dashboard at 2 requests per second.
- Routes: `/`, `/metrics`, `/api/fees`, and `/api/watch`.
- Resource readings: Docker cgroup working set, RSS, one-core CPU percentage, and throttled CPU time.
- Request readings: count, errors, and median per-cycle p50 and p95 latency.
- Wallet scans had finished before the run. Both dashboards served live wallet data, though the Go preview had one additional public example row, so response state was close rather than byte-identical.

The Go preview used a separate read-only RPC gateway as a deployment safety boundary. The Go application metrics below exclude that gateway. Gateway overhead is reported separately so the application runtime and the temporary preview architecture are not conflated.

## Median load results

| Measurement | Python | Go application |
| --- | ---: | ---: |
| Requests | 180 | 180 |
| Errors | 0 | 0 |
| Working set | 27,541,504 B (26.27 MiB) | 8,505,344 B (8.11 MiB) |
| RSS | 36,841,472 B (35.13 MiB) | 17,125,376 B (16.33 MiB) |
| CPU, one core | 6.326% | 1.800% |
| Latency p50 | 21.504 ms | 21.301 ms |
| Latency p95 | 73.053 ms | 26.545 ms |

Relative to Python, the Go application used 69.12% less working-set memory, 53.52% less RSS, and 71.55% less CPU during its matched load windows.

During Go load, the preview-only RPC gateway had a median 17,981,440 B (17.15 MiB) working set, 30,466,048 B (29.06 MiB) RSS, and 1.989% one-core CPU. The combined preview application and gateway used 25.26 MiB working set and 3.789% one-core CPU. This gateway is not part of the Go application runtime.

Raw per-cycle measurements are in [`report.json`](report.json). Repository, release archive, and container image sizes are intentionally omitted because they must be recomputed from the final committed source and image.
