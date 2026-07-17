#!/usr/bin/env bash
# End-to-end test of `./stack upgrade`. Builds a two-release local repo
# (v0.0.1 -> v0.0.2) with a local "origin", boots the OLD release, runs
# `./stack upgrade`, and asserts it moved to the NEW release with the stack
# healthy, the dashboard serving the new version, and a pre-upgrade backup
# written. Deterministic — no GitHub dependency. Both images are pre-built
# locally (tagged as the compose image refs) so neither the boot nor the
# upgrade's `up -d` has to touch a registry for the unpublished test tags.
# Heavy (real containers): self-skips unless in CI or RUN_E2E; refuses to
# touch a real deployment.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${CI:-}" ] && [ -z "${RUN_E2E:-}" ]; then
  echo "SKIP: test_upgrade.sh (set RUN_E2E=1; boots real containers on port 80)"
  exit 0
fi
if [ -f "$src/config.json" ] || [ -f "$src/.env" ]; then
  echo "SKIP: test_upgrade.sh (real config.json/.env present — run from a clean checkout)"
  exit 0
fi

work=$(mktemp -d)
bare="$(mktemp -d)/upstream.git"
data=$(mktemp -d)
chmod 777 "$data" # bitcoind runs as uid 1000; CI runners often aren't

fail() {
  echo "FAIL: $1"
  (cd "$work" && docker compose logs --tail 30 2>/dev/null) || true
  exit 1
}
cleanup() {
  (cd "$work" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  docker run --rm -v "$data":/c alpine:3.24 sh -c 'rm -rf /c/* /c/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$work" "${bare%/*}" "$data" 2>/dev/null || true
}
trap cleanup EXIT

# A fresh repo from the current tree (no real history/tags) with two releases.
git -C "$src" archive HEAD | tar -x -C "$work"
git init --bare -q "$bare"
cd "$work"
git init -q
git config user.email t@t
git config user.name t
printf '0.0.1\n' >VERSION && git add -A && git commit -qm r1 && git tag v0.0.1
printf '0.0.2\n' >VERSION && git add -A && git commit -qm r2 && git tag v0.0.2
git remote add origin "$bare"
git push -q origin HEAD --tags
# Pin the datadir via config.json (gitignored, so it survives the upgrade's
# checkout and is re-rendered identically on every configure).
printf '{"bitcoin": {"data_dir": "%s"}}\n' "$data" >config.json

# Pre-build both releases' images and tag them as the compose image refs
# (ghcr…:0.0.2 / :0.0.1). The dashboard bakes VERSION at build time, so each
# tag carries the right version. Building avoids any registry inspect of the
# unpublished tags (which Docker Desktop answers with a 500).
for v in 0.0.2 0.0.1; do
  git checkout -q "v$v"
  ./configure.sh >/dev/null
  docker compose build >/dev/null 2>&1 || fail "could not build images for v$v"
done
[ "$(cat VERSION)" = "0.0.1" ] || fail "setup: expected to end on v0.0.1"

# Boot the OLD release (uses the local ghcr…:0.0.1 images just built).
docker compose up -d --wait --wait-timeout 300 || fail "v0.0.1 did not come up healthy"

# The upgrade: fetch tags, see v0.0.2 is newer, back up, check out, re-apply.
out=$(./stack upgrade 2>&1) || fail "upgrade exited non-zero:
$out"
echo "$out" | grep -q "Upgrading v0.0.1 -> v0.0.2" || fail "upgrade did not move 0.0.1 -> 0.0.2:
$out"
[ "$(cat VERSION)" = "0.0.2" ] || fail "checkout did not land on v0.0.2 (VERSION=$(cat VERSION))"
ls backups/stack-backup-*.tar.gz >/dev/null 2>&1 || fail "no pre-upgrade backup was written"

# The stack must be healthy on the new release. `up -d` recreated the dashboard
# (new image), so its healthcheck restarts — wait for it to re-heal.
ok=
for _ in $(seq 1 30); do
  unhealthy=
  for c in tor bitcoin dashboard; do
    h=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || echo missing)
    [ "$h" = healthy ] || unhealthy="$c=$h"
  done
  [ -z "$unhealthy" ] && {
    ok=1
    break
  }
  sleep 5
done
[ -n "$ok" ] || fail "stack not healthy after upgrade ($unhealthy)"
# and serving the new baked version
curl -fsS localhost 2>/dev/null | grep -q "v0.0.2" || fail "dashboard not serving v0.0.2 after upgrade"

echo "PASS: test_upgrade.sh (v0.0.1 -> v0.0.2, stack healthy, backup written)"
