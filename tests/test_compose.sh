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
export BITCOIN_RPCAUTH_SALT=cafe0123cafe0123cafe0123cafe0123
export BITCOIN_RPCAUTH_HASH=deadbeef
export BITCOIN_DATA_DIR=./data/bitcoin
export BITCOIN_DBCACHE=1234
export BITCOIN_PRUNE=555
export WATCH_WALLETS_B64=watchblob

rendered=$(docker compose --env-file /dev/null config)

# Settings reach bitcoind's environment
echo "$rendered" | grep -q 'RPC_USER: testuser' || fail "RPC_USER not interpolated"
echo "$rendered" | grep -q 'RPCAUTH_SALT: cafe0123cafe0123cafe0123cafe0123' || fail "RPCAUTH_SALT not interpolated"
echo "$rendered" | grep -q 'RPCAUTH_HASH: deadbeef' || fail "RPCAUTH_HASH not interpolated"
echo "$rendered" | grep -q 'DBCACHE: "1234"' || fail "DBCACHE not interpolated"
echo "$rendered" | grep -q 'PRUNE: "555"' || fail "PRUNE not interpolated"
echo "$rendered" | grep -q 'INBOUND_ONION: "0"' || fail "INBOUND_ONION default not applied"
echo "$rendered" | grep -q 'DASHBOARD_ONION: "0"' || fail "DASHBOARD_ONION default not applied"
echo "$rendered" | grep -q 'NODE_NAME: bitcoin-node' || fail "NODE_NAME default not applied"
echo "$rendered" | grep -q 'ALERT_NEW_BLOCK: "0"' || fail "ALERT_NEW_BLOCK default not applied"
echo "$rendered" | grep -q 'WATCH_WALLETS_B64: watchblob' || fail "WATCH_WALLETS_B64 not interpolated"

# The plaintext RPC password reaches ONLY the dashboard (bitcoind gets the
# rpcauth hash) — exactly one occurrence in the whole rendered config
count=$(echo "$rendered" | grep -c 'testpass' || true)
[ "$count" = "1" ] || fail "plaintext password appears $count times in rendered config, expected 1 (dashboard only)"

# Entrypoint defers expansion to container runtime ($$ escaped), so secrets
# are never baked into the rendered command line.
# All flags must sit on ONE line with the exec: a YAML-induced line break
# after -conf silently drops them (found the hard way; see tests/test_e2e.sh).
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'exec bitcoind -datadir=/data -conf=/data/bitcoin.conf -rpcauth="$$RPCAUTH" -dbcache="$$DBCACHE" -prune="$$PRUNE" -blockfilterindex="$$BLOCKFILTERINDEX" $$NET_ARGS $$ONION_ARGS' ||
  fail "bitcoind exec line is missing runtime-env flags (or they were split onto another line)"
echo "$rendered" | grep -q -- "-rpcauth=testuser" && fail "credentials baked into rendered command line"
# default outbound routing is Tor-only (clearnet sync is opt-in)
echo "$rendered" | grep -qF 'NET_ARGS="-proxy=172.29.0.25:9050 -onion=172.29.0.25:9050 -onlynet=onion"' ||
  fail "default (Tor-only) routing missing from the entrypoint"

# the full branch line, pinned verbatim: clearnet-sync (the IP-exposing opt-in)
# must sit in the then-branch and Tor-only in the else — a value typo OR a
# then/else swap both fail this (same whole-line style as the exec check above)
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'if [ "$$SYNC_OVER_CLEARNET" = "1" ]; then NET_ARGS="-onion=172.29.0.25:9050"; else NET_ARGS="-proxy=172.29.0.25:9050 -onion=172.29.0.25:9050 -onlynet=onion"; fi' ||
  fail "SYNC_OVER_CLEARNET branch line changed — check both routing branches in the entrypoint"

# inbound-onion branch, pinned verbatim: regressing this once silently killed
# outbound onion sync (commit 0654ac0). Only appears when INBOUND_ONION=1.
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'if [ "$$INBOUND_ONION" = "1" ]; then ONION_ARGS="-listen=1 -listenonion=1 -torcontrol=172.29.0.25:9051"; fi' ||
  fail "INBOUND_ONION branch line changed — check the inbound onion-service flags in the entrypoint"

# The only published port is the dashboard on host port 80
ports=$(echo "$rendered" | grep -c 'published: "80"' || true)
published=$(echo "$rendered" | grep -c 'published:' || true)
[ "$ports" = "1" ] || fail "expected dashboard published on 80, got $ports"
[ "$published" = "1" ] || fail "expected exactly 1 published port, got $published"

# Without credentials the stack refuses to start
if env -u BITCOIN_RPC_USER -u BITCOIN_RPC_PASSWORD docker compose --env-file /dev/null config >/dev/null 2>&1; then
  fail "compose config succeeded without credentials"
fi

# The dashboard mounts the chain read-only and gets a separate writable volume
# for watch-only wallet state (so the chain datadir is never writable from it)
echo "$rendered" | grep -q 'target: /data' || fail "dashboard missing /data mount"
echo "$rendered" | grep -q 'target: /state' || fail "dashboard missing writable /state volume"

echo "PASS: test_compose.sh"
