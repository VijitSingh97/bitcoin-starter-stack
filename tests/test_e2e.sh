#!/usr/bin/env bash
# Boots the real stack through the DOCUMENTED setup path: piped answers to
# ./stack init write config.json, a jq edit customizes it (the documented
# edit-then-apply loop), configure.sh renders .env with auto-generated RPC
# credentials, and docker compose boots from that .env. Then asserts the
# wiring end to end: bitcoind accepts the rpcauth-hashed credentials over
# RPC, the plaintext password never enters the bitcoin container, the
# inbound onion service comes up, and the dashboard enforces its auth.
# With E2E_SYNC=1 it additionally proves sync STARTS (onion-only peers
# found, headers advancing — not the whole sync) for BOTH setup paths:
# the wizard config it booted with, and a second zero-config boot (bare
# ./stack up). Real Tor traffic, takes minutes, so it's opt-in (off in
# CI; run it on real hardware). Post-sync behavior on an already-synced
# node is tests/test_postsync.sh.
# This is the test that catches config-plumbing bugs the static contract
# test can't.
#
# Runs real containers (fixed names/ports) and writes config.json/.env in
# the checkout, so it self-skips unless in CI or explicitly requested, and
# refuses to run where a config already exists.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${CI:-}" ] && [ -z "${RUN_E2E:-}" ]; then
  echo "SKIP: test_e2e.sh (set RUN_E2E=1; boots real containers on port 80)"
  exit 0
fi

# Never clobber a real deployment: a production checkout has these files.
if [ -f config.json ] || [ -f .env ]; then
  echo "FAIL: config.json/.env already exist — run the e2e from a clean checkout"
  exit 1
fi

fail() {
  echo "FAIL: $1"
  docker compose ps || true
  docker compose logs --tail 50 || true
  exit 1
}

BITCOIN_DATA_DIR=$(mktemp -d)
chmod 777 "$BITCOIN_DATA_DIR" # bitcoind runs as uid 1000; CI runners often aren't

# bitcoind writes as uid 1000, which the invoking user may not be able to
# delete — clean the datadir through a root container instead of rm -rf
cleanup() {
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$BITCOIN_DATA_DIR":/cleanup alpine:3.24 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$BITCOIN_DATA_DIR" 2>/dev/null || true
  rm -f config.json .env # created by this test (guarded above)
}
trap cleanup EXIT

# Setup exactly as a user does it. Wizard answers: RPC user/pass Enter
# (auto-generate), dashboard password e2edash, dashboard onion y, inbound
# onion y, clearnet n, prune 1 GB, don't start yet.
printf '\n\ne2edash\ny\ny\nn\n1\nn\n' | ./stack init >/dev/null
# The documented customize loop: edit config.json, re-render. Point the
# datadir at the temp dir and shrink dbcache for CI-sized runners.
jq --arg d "$BITCOIN_DATA_DIR" '.bitcoin.data_dir = $d | .bitcoin.dbcache_mb = 300' \
  config.json >config.json.tmp && mv config.json.tmp config.json
./configure.sh >/dev/null

# The credentials the setup generated — every later assertion uses these.
rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' .env)
rpc_pass=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' .env)
if [ -z "$rpc_user" ] || [ -z "$rpc_pass" ]; then
  fail "configure.sh did not render RPC credentials into .env"
fi

docker compose up -d --build --wait --wait-timeout 300 ||
  fail "stack did not reach healthy within 5 minutes"
# --wait passing also proves the cookie-based bitcoin healthcheck works

# rpcauth accepts the generated plaintext password end to end
docker exec bitcoin bitcoin-cli -rpcuser="$rpc_user" -rpcpassword="$rpc_pass" getblockchaininfo |
  grep -q '"chain"' || fail "RPC rejected the generated password against the rpcauth hash"

# ...but the plaintext password is nowhere in the bitcoin container's config
docker inspect bitcoin | grep -q "$rpc_pass" && fail "plaintext RPC password leaked into the bitcoin container"

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

# Sync-start check (opt-in: real Tor traffic, takes many minutes). Proves the
# node finds peers, that every peer is an onion peer, and that header sync
# begins — not the whole sync, just that it starts. Cold-cache onion peer
# discovery on an empty datadir is slow, so the budgets are generous — run
# this on real hardware, not in the CI gate.
sync_starts() { # $1: label for messages
  # separate the failure modes: Tor itself not bootstrapping (up to 5 min)
  # vs. bitcoind not finding onion peers through a working Tor
  boot_ok=""
  for _ in $(seq 1 30); do
    if docker logs tor 2>&1 | grep -q "Bootstrapped 100"; then
      boot_ok=1
      break
    fi
    sleep 10
  done
  [ -n "$boot_ok" ] || fail "$1: tor never reached Bootstrapped 100%"

  peer_ok=""
  for _ in $( # up to 20 min for the first peer: cold onion discovery is slow
    seq 1 120
  ); do
    conns=$(docker exec bitcoin bitcoin-cli -datadir=/data getnetworkinfo | grep -o '"connections": *[0-9]*' | grep -o '[0-9]*' || echo 0)
    if [ "${conns:-0}" -ge 1 ]; then
      peer_ok=1
      break
    fi
    sleep 10
  done
  [ -n "$peer_ok" ] || fail "$1: no peers found over Tor within 20 minutes (tor was bootstrapped)"

  clearnet_peers=$(docker exec bitcoin bitcoin-cli -datadir=/data getpeerinfo | grep '"addr":' | grep -v '\.onion' || true)
  [ -z "$clearnet_peers" ] || fail "$1: non-onion peer(s) connected: $clearnet_peers"

  hdr_ok=""
  for _ in $( # up to 5 more min for the first headers
    seq 1 30
  ); do
    hdrs=$(docker exec bitcoin bitcoin-cli -datadir=/data getblockchaininfo | grep -o '"headers": *[0-9]*' | grep -o '[0-9]*' || echo 0)
    if [ "${hdrs:-0}" -gt 0 ]; then
      hdr_ok=1
      break
    fi
    sleep 10
  done
  [ -n "$hdr_ok" ] || fail "$1: headers never advanced — sync did not start"
  echo "  $1: sync starts — $conns peer(s), all onion, headers at $hdrs"
}

if [ -n "${E2E_SYNC:-}" ]; then
  sync_starts "wizard setup"

  # Second setup variant: the headline ZERO-CONFIG path — no config.json at
  # all, exactly what a bare ./stack up renders. Tear the wizard stack down
  # (cleanup between phases), boot from configure.sh defaults, and prove
  # sync starts there too. Images are already built; only the datadir is
  # redirected at the temp dir so cleanup stays single-path.
  docker compose down -v --remove-orphans >/dev/null 2>&1
  rm -f config.json .env
  docker run --rm -v "$BITCOIN_DATA_DIR":/cleanup alpine:3.24 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  ./configure.sh >/dev/null # zero-config: defaults + auto-generated creds
  sed -i.bak "s|^BITCOIN_DATA_DIR=.*|BITCOIN_DATA_DIR=$BITCOIN_DATA_DIR|" .env && rm -f .env.bak
  docker compose up -d --wait --wait-timeout 300 ||
    fail "zero-config: stack did not reach healthy"
  code=$(curl -s -o /dev/null -w '%{http_code}' localhost:80)
  [ "$code" = "200" ] || fail "zero-config: dashboard not open without a password (HTTP $code)"
  sync_starts "zero-config setup"
else
  echo "  (sync-start checks skipped — set E2E_SYNC=1 to include them)"
fi

echo "PASS: test_e2e.sh"
