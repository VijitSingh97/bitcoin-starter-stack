#!/usr/bin/env bash
# Boots the real stack against an empty datadir and asserts the wiring
# end to end: bitcoind accepts the rendered credentials over RPC, and the
# dashboard serves live stats (not its holding page). This is the test
# that catches config-plumbing bugs the static contract test can't.
#
# Runs real containers (with fixed names/ports), so it self-skips unless
# in CI or explicitly requested — it would collide with a running stack.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CI:-}" ] && [ -z "${RUN_E2E:-}" ]; then
  echo "SKIP: test_e2e.sh (set RUN_E2E=1; boots real containers on port 8000)"
  exit 0
fi

fail() {
  echo "FAIL: $1"
  docker compose --env-file /dev/null ps || true
  docker compose --env-file /dev/null logs --tail 50 || true
  exit 1
}

export BITCOIN_RPC_USER=e2euser
export BITCOIN_RPC_PASSWORD=e2epass
export BITCOIN_DBCACHE=300
export BITCOIN_PRUNE=550 # exercises the pruned path and keeps the test datadir small
BITCOIN_DATA_DIR=$(mktemp -d)
export BITCOIN_DATA_DIR
chmod 777 "$BITCOIN_DATA_DIR" # bitcoind runs as uid 1000; CI runners often aren't

# bitcoind writes as uid 1000, which the invoking user may not be able to
# delete — clean the datadir through a root container instead of rm -rf
cleanup() {
  docker compose --env-file /dev/null down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$BITCOIN_DATA_DIR":/cleanup alpine:3.22 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$BITCOIN_DATA_DIR" 2>/dev/null || true
}
trap cleanup EXIT

docker compose --env-file /dev/null up -d --build --wait --wait-timeout 300 ||
  fail "stack did not reach healthy within 5 minutes"

# bitcoind accepts the credentials that configure.sh/compose plumbed through
docker exec bitcoin sh -c 'bitcoin-cli -rpcuser="$RPC_USER" -rpcpassword="$RPC_PASSWORD" getblockchaininfo' |
  grep -q '"chain"' || fail "RPC rejected the rendered credentials"

# The dashboard authenticates too, and renders stats instead of the holding page
for _ in 1 2 3 4 5 6; do
  body=$(curl -sf localhost:8000 || true)
  echo "$body" | grep -q "Sync Progress" && break
  sleep 5
done
echo "$body" | grep -q "Sync Progress" || fail "dashboard never rendered live stats"

echo "PASS: test_e2e.sh"
