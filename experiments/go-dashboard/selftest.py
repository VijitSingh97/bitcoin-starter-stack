#!/usr/bin/env python3
import importlib.util
import os
import re
import subprocess
import tempfile
from pathlib import Path
from unittest import mock


root = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("benchmark", root / "benchmark.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)

assert benchmark.percentile([], 0.95) is None
assert benchmark.percentile([1, 2, 3, 4], 0.50) == 2.5
assert abs(benchmark.percentile([1, 2, 3, 4], 0.95) - 3.85) < 0.000001
assert benchmark.cpu_percent(10, 500_010, 1) == 50
before = {"users": {"go": {"uptime": 1}, "py": {}}, "rejected": 0}
after = {"users": {"go": {"uptime": 3, "getnetworkinfo": 2}, "py": {}}, "rejected": 0}
assert benchmark.delta_counts(before, after, "go") == {"getnetworkinfo": 2, "uptime": 2}

with tempfile.TemporaryDirectory() as tmp:
    cgroup = Path(tmp)
    (cgroup / "cpu.stat").write_text("usage_usec 20\nnr_throttled 2\nthrottled_usec 3\n")
    assert benchmark.key_values(cgroup / "cpu.stat")["usage_usec"] == 20

with mock.patch.object(benchmark, "docker_pid", return_value=123), \
     mock.patch.object(benchmark, "cgroup_dir") as find_cgroup, \
     mock.patch.object(benchmark, "proc_status", return_value={"rss_bytes": 7, "hwm_bytes": 9, "threads": 2}):
    with tempfile.TemporaryDirectory() as tmp:
        cgroup = Path(tmp)
        (cgroup / "memory.current").write_text("1000\n")
        (cgroup / "memory.peak").write_text("1200\n")
        (cgroup / "memory.stat").write_text("inactive_file 200\n")
        (cgroup / "cpu.stat").write_text("usage_usec 20\nnr_throttled 2\nthrottled_usec 3\n")
        find_cgroup.return_value = cgroup
        row = benchmark.cgroup_sample("test")
        assert row["working_set_bytes"] == 800
        assert row["memory_cgroup_peak_bytes"] == 1200
        assert row["cpu_usage_usec"] == 20

fixture_spec = importlib.util.spec_from_file_location("fixture", root / "fixture.py")
fixture = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixture)
assert set(fixture.RESULTS) == {"getblockchaininfo", "getnetworkinfo", "getpeerinfo", "uptime", "getmempoolinfo", "estimatesmartfee"}
auth = __import__("base64").b64encode(b"go:fakepw").decode()
assert fixture.authenticate(f"Basic {auth}") == "go"
assert fixture.authenticate("Basic broken") is None

runner = (root / "run-benchmark.sh").read_text()
benchmark_source = (root / "benchmark.py").read_text()
assert "docker system prune" not in runner and "docker image prune" not in runner
assert "docker pull" not in runner and "docker network create --internal" in runner
docker_runs = [line for line in runner.replace("\\\n", " ").splitlines() if line.startswith("docker run ")]
assert docker_runs and all(re.search(r"(^|\s)(-p|--publish)(\s|=)", line) is None for line in docker_runs)
assert all(port not in runner for port in ("18081", "18082", "18083"))
for argument in ("--go-url", "--python-url", "--fixture-url"):
    assert argument in runner and argument in benchmark_source
assert 'container["NetworkSettings"]["Networks"]' in runner and 'get("Gateway")' in runner
assert "docker rm -f \"$name\"" in runner and "[[ $name == bss-go-bench-* ]]" in runner
assert "GO_BENCH_SOURCE_MANIFEST_SHA256" in runner and "sha256sum -c MANIFEST.sha256" in runner
assert "GO_BENCH_IMAGE_ID" in runner and "{{.Id}}" in runner
assert "{{.Config.Image}}' dashboard" in runner and "{{.Image}}' dashboard" in runner
assert runner.index("trap finish EXIT") > runner.index("snapshot_production \"$before\"")
assert "bss-go-bench.run=$run_id" in runner and "refusing to remove unowned" in runner

with tempfile.TemporaryDirectory() as tmp:
    fake_docker = Path(tmp) / "docker"
    calls = Path(tmp) / "calls"
    fake_docker.write_text("""#!/bin/sh
printf '%s\\n' "$*" >>"$FAKE_DOCKER_CALLS"
case "$*" in
  "container inspect "*) exit 0 ;;
  "inspect -f "*) echo other-owner; exit 0 ;;
  "network inspect -f "*) echo other-owner; exit 0 ;;
  "network inspect "*) exit 0 ;;
  *) exit 0 ;;
esac
""")
    fake_docker.chmod(0o755)
    environment = os.environ.copy()
    environment["PATH"] = tmp + os.pathsep + environment["PATH"]
    environment["FAKE_DOCKER_CALLS"] = str(calls)
    subprocess.run([str(root / "run-benchmark.sh"), "--selftest-cleanup"], check=True, env=environment, capture_output=True, text=True)
    logged = calls.read_text()
    assert "rm -f" not in logged and "network rm" not in logged

with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / "source"
    source.mkdir()
    (source / "main.go").write_text("package main\n")
    digest = __import__("hashlib").sha256((source / "main.go").read_bytes()).hexdigest()
    (source / "MANIFEST.sha256").write_text(f"{digest}  main.go\n")
    manifest_digest = __import__("hashlib").sha256((source / "MANIFEST.sha256").read_bytes()).hexdigest()
    command = [str(root / "run-benchmark.sh"), "--selftest-source", str(source), manifest_digest]
    subprocess.run(command, check=True, capture_output=True, text=True)
    (source / "extra.py").write_text("raise RuntimeError\n")
    extra = subprocess.run(command, capture_output=True, text=True)
    assert extra.returncode != 0 and "file set does not exactly match" in extra.stderr
    (source / "extra.py").unlink()
    (source / "link").symlink_to("main.go")
    linked = subprocess.run(command, capture_output=True, text=True)
    assert linked.returncode != 0 and "symlink or non-regular" in linked.stderr

print("benchmark self-test: PASS")
