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
WALLET_DATA_DIR=$(mktemp -d)
chmod 777 "$BITCOIN_DATA_DIR" "$WALLET_DATA_DIR" # bitcoind runs as uid 1000; CI runners often aren't

# bitcoind writes as uid 1000, which the invoking user may not be able to
# delete — clean the datadir through a root container instead of rm -rf
cleanup() {
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$BITCOIN_DATA_DIR":/cleanup alpine:3.24 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  docker run --rm -v "$WALLET_DATA_DIR":/cleanup alpine:3.24 sh -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  rmdir "$BITCOIN_DATA_DIR" 2>/dev/null || true
  rmdir "$WALLET_DATA_DIR" 2>/dev/null || true
  rm -f config.json .env # created by this test (guarded above)
}
trap cleanup EXIT

# Setup exactly as a user does it. Wizard answers: RPC user/pass Enter
# (auto-generate), dashboard password e2edash, dashboard onion y, upgrade
# button n (agent covered by test_upgrade.sh), inbound onion y, LAN RPC n, prune 1 GB,
# don't start yet.
printf '\n\ne2edash\ny\nn\ny\nn\n1\nn\n' | ./stack init >/dev/null
# The documented customize loop: edit config.json, re-render. Point the
# datadir at the temp dir, bind the dashboard to this host's LAN address, and
# shrink dbcache for CI-sized runners.
lan_ip=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(("192.0.2.1", 9))
print(s.getsockname()[0])
s.close()
PY
)
jq --arg d "$BITCOIN_DATA_DIR" --arg ip "$lan_ip" \
  '.bitcoin.data_dir = $d | .bitcoin.dbcache_mb = 300 | .bitcoin.rpc_expose = true | .bitcoin.rpc_bind_ip = $ip | .bitcoin.rpc_port = 18332 | .dashboard.bind_ip = $ip' \
  config.json >config.json.tmp && mv config.json.tmp config.json
./configure.sh >/dev/null
dashboard_url="http://$lan_ip:80"

# The credentials the setup generated — every later assertion uses these.
rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' .env)
rpc_pass=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' .env)
if [ -z "$rpc_user" ] || [ -z "$rpc_pass" ]; then
  fail "configure.sh did not render RPC credentials into .env"
fi

docker compose up -d --build --wait --wait-timeout 300 ||
  fail "stack did not reach healthy within 5 minutes"
# --wait passing also proves the cookie-based bitcoin healthcheck works
docker exec dashboard sh -c 'test -z "$(find /app -name "*.test.mjs" -o -name "*_test.go" -o -name tests -o -name parity)"' ||
  fail "dashboard image includes development-only files"

# rpcauth accepts the generated plaintext password end to end
docker exec bitcoin bitcoin-cli -rpcuser="$rpc_user" -rpcpassword="$rpc_pass" getblockchaininfo |
  grep -q '"chain"' || fail "RPC rejected the generated password against the rpcauth hash"
curl --noproxy '*' -fsS --user "$rpc_user:$rpc_pass" -H 'content-type: application/json' \
  --data-binary '{"jsonrpc":"1.0","id":"e2e","method":"getblockchaininfo","params":[]}' \
  "http://$lan_ip:18332" | jq -e '.result.chain != null and .error == null' >/dev/null ||
  fail "LAN RPC relay did not authenticate to Core"

# ...but the plaintext password is nowhere in the bitcoin container's config
docker inspect bitcoin | grep -q "$rpc_pass" && fail "plaintext RPC password leaked into the bitcoin container"

# Dashboard enforces basic auth when a password is set
code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "$dashboard_url")
[ "$code" = "401" ] || fail "dashboard served without auth (HTTP $code, expected 401)"

# With the password, it authenticates to the node and renders live stats
body=""
for _ in 1 2 3 4 5 6; do
  body=$(curl --noproxy '*' -sf -u x:e2edash "$dashboard_url" || true)
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
curl --noproxy '*' -sf -u x:e2edash "$dashboard_url/metrics" | grep -q "bitcoin_node_up 1" ||
  fail "metrics endpoint missing bitcoin_node_up"

curl --noproxy '*' -sf -u x:e2edash "$dashboard_url/api/settings" | grep -q '"can_configure":true' ||
  fail "authenticated LAN settings are not configurable"
settings_body='{"telegram_enabled":false,"telegram_chat_id":"","healthchecks_enabled":false,"alert_new_block":true}'
code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -H 'X-Requested-With: fetch' \
  -H 'Content-Type: application/json' -d "$settings_body" "$dashboard_url/api/settings")
[ "$code" = 401 ] || fail "unauthenticated LAN notification settings write was not denied"
code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -u x:wrong -H 'X-Requested-With: fetch' \
  -H 'Content-Type: application/json' -d "$settings_body" "$dashboard_url/api/settings")
[ "$code" = 401 ] || fail "wrong-password LAN notification settings write was not denied"
code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -u x:e2edash \
  -H 'Content-Type: application/json' -d "$settings_body" "$dashboard_url/api/settings")
[ "$code" = 403 ] || fail "LAN notification settings write without CSRF header was not denied"
curl --noproxy '*' -sf -u x:e2edash -H 'X-Requested-With: fetch' -H 'Content-Type: application/json' \
  -d "$settings_body" "$dashboard_url/api/settings" | grep -q '"overridden":true' ||
  fail "authenticated LAN notification settings write failed"
docker exec dashboard sh -c 'test "$(stat -c %a /state/notification_settings.json)" = 600' ||
  fail "saved notification settings are not private"
docker compose up -d --no-deps --force-recreate --wait --wait-timeout 300 dashboard ||
  fail "dashboard recreation failed"
curl --noproxy '*' -sf -u x:e2edash "$dashboard_url/api/settings" | grep -q '"alert_new_block":true' ||
  fail "notification settings did not survive container recreation"
settings_body='{"reset":true}'
curl --noproxy '*' -sf -u x:e2edash -H 'X-Requested-With: fetch' -H 'Content-Type: application/json' \
  -d "$settings_body" "$dashboard_url/api/settings" | grep -q '"overridden":false' ||
  fail "notification reset did not restore the server configuration"

restarts=$(docker inspect tor --format '{{.RestartCount}}')
docker exec tor sh -c 'kill "$(pidof socat)"'
forwarder_recovered=""
for _ in $(seq 1 30); do
  current=$(docker inspect tor --format '{{.RestartCount}}')
  if [ "$current" -gt "$restarts" ] && curl --noproxy '*' -sf -u x:e2edash "$dashboard_url/metrics" | grep -q "bitcoin_node_up 1"; then
    forwarder_recovered=1
    break
  fi
  sleep 2
done
[ -n "$forwarder_recovered" ] || fail "Tor/dashboard forwarder did not restart cleanly"

restarts=$(docker inspect tor --format '{{.RestartCount}}')
docker exec tor sh -c 'kill "$(pidof tor)"'
tor_recovered=""
for _ in $(seq 1 30); do
  current=$(docker inspect tor --format '{{.RestartCount}}')
  if [ "$current" -gt "$restarts" ] && curl --noproxy '*' -sf -u x:e2edash "$dashboard_url/metrics" | grep -q "bitcoin_node_up 1"; then
    tor_recovered=1
    break
  fi
  sleep 2
done
[ -n "$tor_recovered" ] || fail "Tor child failure did not restart the supervised container"

# Tor must be the only service with an external route. Prove Tor reaches the
# network, then stop it and make real direct TCP and DNS attempts from both
# application network namespaces; every attempt must fail closed.
tor_bootstrapped=""
for _ in $(seq 1 30); do
  if docker logs tor 2>&1 | grep "Bootstrapped 100" >/dev/null; then
    tor_bootstrapped=1
    break
  fi
  sleep 10
done
[ -n "$tor_bootstrapped" ] || fail "Tor never reached the public network"
helper_image=$(docker inspect dashboard --format '{{.Config.Image}}')
docker exec dashboard sh -c 'command -v nc >/dev/null && command -v nslookup >/dev/null && nc -z -w 3 172.29.0.26 8332' ||
  fail "dashboard network probes are unavailable or cannot reach local RPC"
docker run --rm --pull never --network container:bitcoin --entrypoint /bin/sh "$helper_image" \
  -c 'command -v nc >/dev/null && command -v nslookup >/dev/null && nc -z -w 3 172.29.0.25 9050' ||
  fail "bitcoin network probes are unavailable or cannot reach local Tor"
docker compose stop tor >/dev/null
[ "$(docker inspect bitcoin --format '{{json .HostConfig.Dns}}')" = '["127.0.0.1"]' ] ||
  fail "bitcoin does not have loopback-only DNS configured"
[ "$(docker inspect dashboard --format '{{json .HostConfig.Dns}}')" = '["127.0.0.1"]' ] ||
  fail "dashboard does not have loopback-only DNS configured"
if docker exec dashboard nc -z -w 3 1.1.1.1 443; then
  fail "dashboard reached a public IP directly with Tor offline"
fi
if docker exec dashboard nc -z -w 3 2606:4700:4700::1111 443; then
  fail "dashboard reached a public IPv6 address directly with Tor offline"
fi
if docker exec dashboard nslookup example.com >/dev/null 2>&1; then
  fail "dashboard resolved public DNS with Tor offline"
fi
if docker exec dashboard nslookup example.com 8.8.8.8 >/dev/null 2>&1; then
  fail "dashboard reached a public DNS server directly with Tor offline"
fi
if docker run --rm --pull never --network container:bitcoin --entrypoint /bin/sh "$helper_image" -c 'nc -z -w 3 1.1.1.1 443'; then
  fail "bitcoin reached a public IP directly with Tor offline"
fi
if docker run --rm --pull never --network container:bitcoin --entrypoint /bin/sh "$helper_image" -c 'nc -z -w 3 2606:4700:4700::1111 443'; then
  fail "bitcoin reached a public IPv6 address directly with Tor offline"
fi
if docker run --rm --pull never --network container:bitcoin --entrypoint /bin/sh "$helper_image" -c 'nslookup example.com' >/dev/null 2>&1; then
  fail "bitcoin resolved public DNS with Tor offline"
fi
if docker run --rm --pull never --network container:bitcoin --entrypoint /bin/sh "$helper_image" -c 'nslookup example.com 8.8.8.8' >/dev/null 2>&1; then
  fail "bitcoin reached a public DNS server directly with Tor offline"
fi
docker compose start tor >/dev/null
for _ in $(seq 1 30); do
  [ "$(docker inspect tor --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = "healthy" ] && break
  sleep 2
done
[ "$(docker inspect tor --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = "healthy" ] ||
  fail "Tor did not recover after fail-closed egress test"

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

  # "sync started" = headers flowing. Core's headers PRESYNC (redownload
  # protection) downloads the whole ~950k-header chain from one peer before
  # getblockchaininfo.headers ever moves off 0 — 15+ min over Tor — so watch
  # getpeerinfo's presynced_headers too; it moves within ~a minute of a good
  # peer.
  hdr_ok=""
  for _ in $( # 10 min for the first headers to flow
    seq 1 60
  ); do
    hdrs=$(docker exec bitcoin bitcoin-cli -datadir=/data getblockchaininfo | grep -o '"headers": *[0-9]*' | grep -o '[0-9]*' || echo 0)
    presync=$(docker exec bitcoin bitcoin-cli -datadir=/data getpeerinfo | grep -oE '"presynced_headers": [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || echo 0)
    if [ "${hdrs:-0}" -gt 0 ] || [ "${presync:-0}" -gt 0 ]; then
      hdr_ok=1
      break
    fi
    sleep 10
  done
  [ -n "$hdr_ok" ] || fail "$1: headers never started flowing — sync did not start"
  echo "  $1: sync starts — $conns peer(s), all onion, headers=$hdrs presync=$presync"
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
  dashboard_url=http://127.0.0.1:80
  code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "$dashboard_url")
  [ "$code" = "200" ] || fail "zero-config: dashboard not open without a password (HTTP $code)"
  sync_starts "zero-config setup"
else
  echo "  (sync-start checks skipped — set E2E_SYNC=1 to include them)"
fi

# Wallet provisioning needs a full node because the API correctly refuses new
# rescans on pruned nodes. Keep the pruned wizard checks above, then recreate
# only bitcoin and dashboard against a separate fresh full-node datadir.
docker compose stop dashboard bitcoin >/dev/null
sed -i.bak \
  -e "s|^BITCOIN_DATA_DIR=.*|BITCOIN_DATA_DIR=$WALLET_DATA_DIR|" \
  -e 's|^BITCOIN_PRUNE=.*|BITCOIN_PRUNE=0|' \
  -e 's|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=e2edash|' \
  .env && rm -f .env.bak
docker compose up -d --no-deps --force-recreate --wait --wait-timeout 300 bitcoin dashboard ||
  fail "full-node wallet stage did not reach healthy"

dashboard_url="http://$(sed -n 's/^DASHBOARD_BIND_IP=//p' .env):80"
body=$(curl --noproxy '*' -sf -u x:e2edash "$dashboard_url" || true)
echo "$body" | grep -q "Full" || fail "dashboard missing full-node badge in wallet stage"
rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' .env)
rpc_pass=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' .env)
BITCOIN_RPC_USER="$rpc_user" BITCOIN_RPC_PASSWORD="$rpc_pass" \
  E2E_DASHBOARD_URL="$dashboard_url" E2E_DASHBOARD_PASSWORD=e2edash python3 build/dashboard/tests/e2e_watch.py ||
  fail "Go watch-only provisioning failed"

echo "PASS: test_e2e.sh"
