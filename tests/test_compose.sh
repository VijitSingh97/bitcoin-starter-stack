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
export DASHBOARD_BIND_IP=127.0.0.1

rendered=$(docker compose --env-file /dev/null config)

# Settings reach bitcoind's environment
echo "$rendered" | grep -q 'RPC_USER: testuser' || fail "RPC_USER not interpolated"
echo "$rendered" | grep -q 'RPCAUTH_SALT: cafe0123cafe0123cafe0123cafe0123' || fail "RPCAUTH_SALT not interpolated"
echo "$rendered" | grep -q 'RPCAUTH_HASH: deadbeef' || fail "RPCAUTH_HASH not interpolated"
echo "$rendered" | grep -q 'DBCACHE: "1234"' || fail "DBCACHE not interpolated"
echo "$rendered" | grep -q 'PRUNE: "555"' || fail "PRUNE not interpolated"
echo "$rendered" | grep -q 'INBOUND_ONION: "0"' || fail "INBOUND_ONION default not applied"
echo "$rendered" | grep -q 'DASHBOARD_ONION: "0"' || fail "DASHBOARD_ONION default not applied"
echo "$rendered" | grep -q 'BITCOIN_RPC_EXPOSE: "0"' || fail "LAN RPC exposure default not applied"
echo "$rendered" | grep -q 'NODE_NAME: bitcoin-node' || fail "NODE_NAME default not applied"
echo "$rendered" | grep -q 'ALERT_NEW_BLOCK: "0"' || fail "ALERT_NEW_BLOCK default not applied"
echo "$rendered" | grep -q 'WATCH_WALLETS_B64: watchblob' || fail "WATCH_WALLETS_B64 not interpolated"
echo "$rendered" | grep -q 'SETTINGS_PORT: "8001"' || fail "internal settings listener is not configured"
grep -qF 'HiddenServicePort 80 172.29.0.27:8001' build/tor/entrypoint.sh || fail "onion dashboard does not use the management listener"

# The plaintext RPC password reaches ONLY the dashboard (bitcoind gets the
# rpcauth hash) — exactly one occurrence in the whole rendered config
count=$(echo "$rendered" | grep -c 'testpass' || true)
[ "$count" = "1" ] || fail "plaintext password appears $count times in rendered config, expected 1 (dashboard only)"

# Entrypoint defers expansion to container runtime ($$ escaped), so secrets
# are never baked into the rendered command line.
# All flags must sit on ONE line with the exec: a YAML-induced line break
# after -conf silently drops them (found the hard way; see tests/test_e2e.sh).
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'exec bitcoind -datadir=/data -conf=/data/bitcoin.conf -rpcauth="$$RPCAUTH" -dbcache="$$DBCACHE" -prune="$$PRUNE" -blockfilterindex="$$BLOCKFILTERINDEX" -maxconnections=125 -inboundrelaypercent=100 $$NET_ARGS $$ONION_ARGS' ||
  fail "bitcoind exec line is missing runtime-env flags (or they were split onto another line)"
echo "$rendered" | grep -q -- "-rpcauth=testuser" && fail "credentials baked into rendered command line"
# Outbound routing is always Tor-only.
echo "$rendered" | grep -qF 'NET_ARGS="-proxy=172.29.0.25:9050 -onion=172.29.0.25:9050 -onlynet=onion"' ||
  fail "Tor-only routing missing from the entrypoint"
echo "$rendered" | grep -q 'SYNC_OVER_CLEARNET' && fail "clearnet sync bypass remains in compose"

# inbound-onion branch, pinned verbatim: regressing this once silently killed
# outbound onion sync (commit 0654ac0). Only appears when INBOUND_ONION=1.
# shellcheck disable=SC2016 # matching the literal $$-escaped text is the point
echo "$rendered" | grep -qF -- 'if [ "$$INBOUND_ONION" = "1" ]; then ONION_ARGS="-listen=1 -listenonion=1 -torcontrol=172.29.0.25:9051"; fi' ||
  fail "INBOUND_ONION branch line changed — check the inbound onion-service flags in the entrypoint"

# Bitcoin and dashboard cannot use Docker's external DNS forwarding, and only
# Tor has a deterministic external default gateway.
[ "$(echo "$rendered" | grep -c '^    dns:$')" = "2" ] || fail "bitcoin/dashboard DNS lock missing"
[ "$(echo "$rendered" | awk '$1 == "dns:" { getline; if ($1 == "-" && $2 == "127.0.0.1") count++ } END { print count + 0 }')" = "2" ] ||
  fail "bitcoin/dashboard DNS is not loopback-only"
echo "$rendered" | grep -A6 '^  btc_net:' | grep -q 'internal: true' || fail "btc_net is not internal"
echo "$rendered" | grep -A5 '^      tor_egress:' | grep -q 'gw_priority: 1' || fail "Tor egress gateway priority missing"

# The only published port is the dashboard on host port 80, loopback by default.
ports=$(echo "$rendered" | grep -c 'published: "80"' || true)
published=$(echo "$rendered" | grep -c 'published:' || true)
[ "$ports" = "1" ] || fail "expected dashboard published on 80, got $ports"
[ "$published" = "1" ] || fail "expected exactly 1 published port, got $published"
echo "$rendered" | grep -q 'published: "8332"' && fail "default config publishes Bitcoin RPC"
echo "$rendered" | grep -q 'host_ip: 127.0.0.1' || fail "dashboard does not bind loopback by default"
tor_port=$(echo "$rendered" | sed -n '/^  tor:$/,/^networks:$/p' | awk '$1 == "host_ip:" { print $2 }')
[ "$tor_port" = "127.0.0.1" ] || fail "dashboard forwarder port is not owned by Tor"
echo "$rendered" | sed -n '/^  dashboard:$/,/^  tor:$/p' | grep -q 'host_ip:' &&
  fail "internal dashboard container still publishes a host port"
echo "$rendered" | sed -n '/^  tor:$/,/^networks:$/p' | grep -q 'nc -z 127.0.0.1 8000' ||
  fail "Tor healthcheck does not cover the dashboard forwarder"
echo "$rendered" | sed -n '/^  tor:$/,/^  bitcoin:$/p' | grep -q 'pids_limit: 100' ||
  fail "Tor container process limit missing"
grep -qF 'socat TCP4-LISTEN:8000,reuseaddr,fork,max-children=32 TCP4:172.29.0.27:8000' build/tor/entrypoint.sh ||
  fail "Tor entrypoint does not forward the published port to the fixed dashboard address"
grep -qF 'socat TCP4-LISTEN:8332,reuseaddr,fork,max-children=32 TCP4:172.29.0.26:8332' build/tor/entrypoint.sh ||
  fail "Tor entrypoint does not relay opt-in LAN RPC to Core"

lan_rendered=$(DASHBOARD_BIND_IP=192.168.1.117 docker compose --env-file /dev/null config)
echo "$lan_rendered" | grep -q 'host_ip: 192.168.1.117' || fail "private-LAN dashboard bind was not rendered"

rpc_rendered=$(BITCOIN_RPC_EXPOSE=1 BITCOIN_RPC_BIND_IP=192.168.1.118 BITCOIN_RPC_PORT=18332 \
  COMPOSE_FILE=docker-compose.yml:docker-compose.rpc.yml docker compose --env-file /dev/null config)
echo "$rpc_rendered" | grep -q 'BITCOIN_RPC_EXPOSE: "1"' || fail "RPC relay was not enabled"
echo "$rpc_rendered" | grep -A5 'target: 8332' | grep -q 'published: "18332"' || fail "custom RPC host port was not rendered"
echo "$rpc_rendered" | grep -B2 -A5 'target: 8332' | grep -q 'host_ip: 192.168.1.118' || fail "private RPC host bind was not rendered"
[ "$(echo "$rpc_rendered" | grep -c 'published:' || true)" = "2" ] || fail "RPC override published an unexpected port"
echo "$rpc_rendered" | sed -n '/^  bitcoin:$/,/^  dashboard:$/p' | grep -q 'published:' &&
  fail "Bitcoin container publishes RPC directly instead of using the Tor relay"

# Without credentials the stack refuses to start
if env -u BITCOIN_RPC_USER -u BITCOIN_RPC_PASSWORD docker compose --env-file /dev/null config >/dev/null 2>&1; then
  fail "compose config succeeded without credentials"
fi

# The dashboard mounts the chain read-only and gets a separate writable volume
# for watch-only wallet state (so the chain datadir is never writable from it)
echo "$rendered" | grep -q 'target: /data' || fail "dashboard missing /data mount"
echo "$rendered" | grep -q 'target: /state' || fail "dashboard missing writable /state volume"

echo "PASS: test_compose.sh"
