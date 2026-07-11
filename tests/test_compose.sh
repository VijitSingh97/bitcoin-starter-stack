#!/usr/bin/env bash
# docker-compose.yml contract: renders with valid env, fails without
# credentials, and exposes nothing to the host except the dashboard port.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

command -v docker >/dev/null || {
  echo "SKIP: test_compose.sh (docker not available)"
  exit 0
}

export BITCOIN_RPC_USER=testuser
export BITCOIN_RPC_PASSWORD=testpass
export BITCOIN_DATA_DIR=./data/bitcoin
export BITCOIN_DBCACHE=1234
export BITCOIN_PRUNE=555

rendered=$(docker compose --env-file /dev/null config)

# Credentials and dbcache reach bitcoind's environment
echo "$rendered" | grep -q 'RPC_USER: testuser' || fail "RPC_USER not interpolated"
echo "$rendered" | grep -q 'RPC_PASSWORD: testpass' || fail "RPC_PASSWORD not interpolated"
echo "$rendered" | grep -q 'DBCACHE: "1234"' || fail "DBCACHE not interpolated"
echo "$rendered" | grep -q 'PRUNE: "555"' || fail "PRUNE not interpolated"

# Entrypoint defers credential expansion to container runtime ($$ escaped),
# so plaintext credentials are never baked into the rendered command line.
# All flags must sit on ONE line with the exec: a YAML-induced line break
# after -conf silently drops them (found the hard way; see tests/test_e2e.sh).
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'exec bitcoind -datadir=/data -conf=/data/bitcoin.conf -rpcuser="$${RPC_USER}" -rpcpassword="$${RPC_PASSWORD}" -dbcache="$${DBCACHE}" -prune="$${PRUNE}"' ||
  fail "bitcoind exec line is missing runtime-env flags (or they were split onto another line)"
echo "$rendered" | grep -q -- "-rpcuser=testuser" && fail "credentials baked into rendered command line"

# The only published port is the dashboard on 8000
ports=$(echo "$rendered" | grep -c 'published: "8000"' || true)
published=$(echo "$rendered" | grep -c 'published:' || true)
[ "$ports" = "1" ] || fail "expected dashboard published on 8000, got $ports"
[ "$published" = "1" ] || fail "expected exactly 1 published port, got $published"

# Without credentials the stack refuses to start
if env -u BITCOIN_RPC_USER -u BITCOIN_RPC_PASSWORD docker compose --env-file /dev/null config >/dev/null 2>&1; then
  fail "compose config succeeded without credentials"
fi

echo "PASS: test_compose.sh"
