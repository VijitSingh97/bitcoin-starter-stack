#!/usr/bin/env bash
# Boots the real stack against an empty datadir and asserts the wiring
# end to end: bitcoind accepts the rpcauth-hashed credentials over RPC,
# the plaintext password never enters the bitcoin container, the inbound
# onion service comes up, and the dashboard enforces its optional auth.
# This is the test that catches config-plumbing bugs the static contract
# test can't.
#
# Runs real containers (with fixed names/ports), so it self-skips unless
# in CI or explicitly requested — it would collide with a running stack.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CI:-}" ] && [ -z "${RUN_E2E:-}" ]; then
  echo "SKIP: test_e2e.sh (set RUN_E2E=1; boots real containers on port 80)"
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
export BITCOIN_INBOUND_ONION=1
export DASHBOARD_PASSWORD=e2edash
export DASHBOARD_ONION=1

# Same rpcauth derivation as configure.sh
BITCOIN_RPCAUTH_SALT=$(openssl rand -hex 16)
BITCOIN_RPCAUTH_HASH=$(printf '%s' "$BITCOIN_RPC_PASSWORD" | openssl dgst -sha256 -hmac "$BITCOIN_RPCAUTH_SALT" -r | cut -d' ' -f1)
export BITCOIN_RPCAUTH_SALT BITCOIN_RPCAUTH_HASH

BITCOIN_DATA_DIR=$(mktemp -d)
export BITCOIN_DATA_DIR
chmod 777 "$BITCOIN_DATA_DIR" # bitcoind runs as uid 1000; CI runners often aren't

# bitcoind writes as uid 1000, which the invoking user may not be able to
# delete — clean the datadir through a root container instead of rm -rf
cleanup() {
  docker compose --env-file /dev/null down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$BITCOIN_DATA_DIR":/cleanup alpine:3.24 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$BITCOIN_DATA_DIR" 2>/dev/null || true
}
trap cleanup EXIT

docker compose --env-file /dev/null up -d --build --wait --wait-timeout 300 ||
  fail "stack did not reach healthy within 5 minutes"
# --wait passing also proves the cookie-based bitcoin healthcheck works

# rpcauth accepts the plaintext password end to end
docker exec bitcoin bitcoin-cli -rpcuser=e2euser -rpcpassword=e2epass getblockchaininfo |
  grep -q '"chain"' || fail "RPC rejected the password against the rpcauth hash"

# ...but the plaintext password is nowhere in the bitcoin container's config
docker inspect bitcoin | grep -q e2epass && fail "plaintext RPC password leaked into the bitcoin container"

# Dashboard enforces basic auth when a password is set
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:80)
[ "$code" = "401" ] || fail "dashboard served without auth (HTTP $code, expected 401)"

# With the password, it authenticates to the node and renders live stats
body=""
for _ in 1 2 3 4 5 6; do
  body=$(curl -sf -u x:e2edash localhost:80 || true)
  echo "$body" | grep -q "Sync Progress" && break
  sleep 5
done
echo "$body" | grep -q "Sync Progress" || fail "dashboard never rendered live stats"
echo "$body" | grep -q "Pruned" || fail "dashboard missing pruned badge on a pruned node"

# The inbound onion service registers with tor's control port: once
# ADD_ONION succeeds, the .onion address appears in localaddresses.
# (Core's "tor: Got service ID" log line only exists with -debug=tor.)
onion_ok=""
for _ in $(seq 1 24); do
  if docker exec bitcoin bitcoin-cli -datadir=/data getnetworkinfo | grep -q '\.onion'; then
    onion_ok=1
    break
  fi
  sleep 10
done
[ -n "$onion_ok" ] || fail "bitcoind never registered an onion service with tor"

# The dashboard hidden service is provisioned (keys + hostname generated)
docker exec tor cat /var/lib/tor/dashboard_onion/hostname | grep -q '\.onion$' ||
  fail "dashboard onion hostname was not provisioned"

# Prometheus metrics behind the same auth
curl -sf -u x:e2edash localhost:80/metrics | grep -q "bitcoin_node_up 1" ||
  fail "metrics endpoint missing bitcoin_node_up"

# Egress audit: every ESTABLISHED connection from the bitcoin and dashboard
# containers must terminate inside the stack subnet (172.29.0.x renders as
# xx001DAC in /proc/net/tcp little-endian hex) — i.e. everything goes to tor
# or intra-stack RPC, and nothing dials clearnet directly.
for c in bitcoin dashboard; do
  bad=$(docker exec "$c" awk 'NR>1 && $4=="01" {split($3,r,":"); if (r[1] !~ /001DAC$/) print r[1]":"r[2]}' /proc/net/tcp 2>/dev/null || true)
  [ -z "$bad" ] || fail "clearnet egress from $c: $bad"
  bad6=$(docker exec "$c" sh -c 'awk "NR>1 && \$4==\"01\" {print \$3}" /proc/net/tcp6 2>/dev/null' || true)
  [ -z "$bad6" ] || fail "unexpected IPv6 egress from $c: $bad6"
done

# Watch-only: provision a wallet of each supported key type against the real
# node — an xpub, a zpub, Satoshi's genesis address, and his genesis pubkey —
# exercising watch.descriptors_for + provision_one (incl. the range fix) and
# confirming a real Core accepts every descriptor form the dashboard builds.
docker cp build/dashboard/tests/e2e_watch.py dashboard:/app/e2e_watch.py >/dev/null
docker exec dashboard python /app/e2e_watch.py || fail "watch-only provisioning failed"

echo "PASS: test_e2e.sh"
