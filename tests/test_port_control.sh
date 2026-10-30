#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

tmp=$(mktemp -d)
listener_pid=
cleanup() {
  if [ -n "$listener_pid" ]; then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fake=$tmp/docker
cat >"$fake" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "$1" = inspect ]; then
  case "$3:$4" in
    '{{.Id}}:dashboard') printf '%s\n' dashboard-id ;;
    '{{.Id}}:tor') printf '%s\n' tor-id ;;
    *project.config_files*':tor-id') printf '%s\n' "${FAKE_TOR_CONFIG_FILES:-$BITCOIN_STACK_ROOT/docker-compose.yml}" ;;
    *project.config_files*) printf '%s\n' "${FAKE_CONFIG_FILES:-$BITCOIN_STACK_ROOT/docker-compose.yml}" ;;
    '{{json .NetworkSettings.Ports}}:tor-id') printf '%s\n' "$FAKE_TOR_PORTS" ;;
    '{{json .NetworkSettings.Ports}}:'*)
      if [ -n "${FAKE_OTHER_PORTS:-}" ]; then printf '%s\n' "$FAKE_OTHER_PORTS"; else printf '%s\n' '{}'; fi
      ;;
  esac
  exit 0
fi
if [ "$1" = ps ] && [ "$2" = -q ]; then
  printf '%s\n' tor-id ${FAKE_OTHER_DOCKER_IDS:-}
  exit 0
fi
if [ "$1" = compose ]; then
  exit 0
fi
[ "$1" = exec ] || exit 1
shift
if [ "${1:-}" = -i ]; then shift; fi
if [ "${1:-}" = -u ]; then shift 2; fi
[ "$1" = dashboard ]
shift
if [ "$1" = sh ] && [ "$2" = -c ]; then
  command=$3
  command=$(printf '%s' "$command" | sed "s#/state#$FAKE_DASH_STATE#g")
  sh -c "$command"
  exit
fi
args=
for arg in "$@"; do
  case "$arg" in /state/*) arg=$FAKE_DASH_STATE/${arg#/state/} ;; esac
  args="$args '$arg'"
done
eval "exec $args"
EOF
chmod +x "$fake" scripts/node-port-control
fake_ss=$tmp/ss
cat >"$fake_ss" <<'EOF'
#!/bin/sh
set -eu
[ "${FAKE_SS_FAIL:-0}" != 1 ] || exit 1
printf '%s' "${FAKE_SS_LISTENERS:-}"
EOF
chmod +x "$fake_ss"

new_case() {
  case_root=$tmp/$1
  mkdir -p "$case_root/root/scripts" "$case_root/state/dashboard" "$case_root/config"
  cp scripts/node-port-control "$case_root/root/scripts/"
  cp configure.sh "$case_root/root/"
  : >"$case_root/root/docker-compose.yml"
  cat >"$case_root/root/stack" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STACK_LOG"
if [ "${FAKE_APPLY_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$FAKE_APPLY_FAIL_MARKER" ]; then
  : >"$FAKE_APPLY_FAIL_MARKER"
  exit 1
fi
[ "${FAKE_APPLY_FAIL:-0}" != 1 ]
EOF
  chmod +x "$case_root/root/stack"
  cat >"$case_root/state/.env" <<'EOF'
DASHBOARD_PASSWORD=testpassword
BITCOIN_RPC_EXPOSE=1
MONERO_RPC_EXPOSE=1
MONERO_ZMQ_EXPOSE=1
EOF
  cat >"$case_root/config/config.json" <<'EOF'
{"bitcoin":{"enabled":true,"node_password":"bitcoinpassword1234567890123456","rpc_expose":true,"rpc_bind_ip":"192.168.1.10","rpc_port":8332,"steady_cpus":0.5},"monero":{"enabled":true,"node_password":"moneropassword12345678901234567","rpc_expose":true,"rpc_bind_ip":"192.168.1.10","rpc_port":18081,"zmq_expose":true,"zmq_bind_ip":"192.168.1.10","zmq_port":18083},"dashboard":{"password":"testpassword"},"other":{"keep":"yes"}}
EOF
  export BITCOIN_STACK_ROOT=$case_root/root
  export BITCOIN_STACK_STATE_DIR=$case_root/state
  export BITCOIN_STACK_CONFIG_DIR=$case_root/config
  export DOCKER_BIN=$fake FAKE_DASH_STATE=$case_root/state/dashboard
  export SS_BIN=$fake_ss
  export FAKE_DOCKER_LOG=$case_root/docker.log FAKE_STACK_LOG=$case_root/stack.log
  export PORT_CONTROL_NOW_EPOCH=1000 FAKE_APPLY_FAIL=0 FAKE_APPLY_FAIL_ONCE=0 FAKE_APPLY_FAIL_MARKER=$case_root/apply-failed
  export FAKE_TOR_PORTS='{"8332/tcp":[{"HostIp":"192.168.1.10","HostPort":"8332"}],"18081/tcp":[{"HostIp":"192.168.1.10","HostPort":"18081"}],"18083/tcp":[{"HostIp":"192.168.1.10","HostPort":"18083"}]}'
  unset FAKE_CONFIG_FILES FAKE_TOR_CONFIG_FILES FAKE_OTHER_DOCKER_IDS FAKE_OTHER_PORTS FAKE_SS_LISTENERS FAKE_SS_FAIL
  : >"$FAKE_DOCKER_LOG"
  : >"$FAKE_STACK_LOG"
}

request() {
  printf '%s\n' "$1" >"$FAKE_DASH_STATE/port-control.request"
}

status() {
  jq -r "$1" "$FAKE_DASH_STATE/port-control.status"
}

new_case close
request '{"id":"11111111111111111111111111111111","changes":[{"port":"bitcoin_rpc","enabled":false},{"port":"monero_zmq","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "Bitcoin RPC remained enabled"
[ "$(jq -r '.monero.zmq_expose' "$case_root/config/config.json")" = false ] || fail "Monero ZMQ remained enabled"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = true ] || fail "unrequested Monero RPC changed"
[ "$(jq -r '.other.keep' "$case_root/config/config.json")" = yes ] || fail "unrelated config changed"
[ "$(stat -c %a "$case_root/config/config.json" 2>/dev/null || stat -f %Lp "$case_root/config/config.json")" = 600 ] || fail "config permissions are not private"
[ "$(status .state)" = applied ] || fail "successful close status was not applied"
[ "$(status '.affected_services | join(",")')" = tor,dashboard ] || fail "status did not name the affected services"
grep -qx apply-port-settings "$FAKE_STACK_LOG" || fail "close did not use the bounded port-settings apply"
grep -q pull "$FAKE_STACK_LOG" && fail "close attempted an image download"
grep -q testpassword "$FAKE_DOCKER_LOG" "$FAKE_STACK_LOG" && fail "close leaked a credential into command logs"
if [ -e "$FAKE_DASH_STATE/port-control.request" ] || [ -e "$FAKE_DASH_STATE/port-control.processing" ]; then
  fail "request was not consumed"
fi
[ "$(cat "$FAKE_DASH_STATE/port-control.capability")" = ready ] || fail "capability heartbeat missing"

request '{"id":"11111111111111111111111111111111","changes":[{"port":"monero_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "replayed request was accepted"
[ "$(grep -c '^apply-port-settings$' "$FAKE_STACK_LOG")" = 1 ] || fail "replay invoked apply"

for payload in \
  '{"id":"22222222222222222222222222222222","changes":[{"port":"unknown","enabled":false}],"requested_at":1000}' \
  '{"id":"33333333333333333333333333333333","changes":[{"port":"monero_rpc","enabled":false},{"port":"monero_rpc","enabled":false}],"requested_at":1000}' \
  '{"id":"44444444444444444444444444444444","changes":[{"port":"monero_rpc","enabled":false}],"requested_at":699}' \
  '{"id":"55555555555555555555555555555555","changes":[{"port":"monero_rpc","enabled":false}],"requested_at":1000,"extra":true}' \
  'not-json'; do
  request "$payload"
  scripts/node-port-control
  [ "$(status .state)" = rejected ] || fail "invalid request was accepted: $payload"
done
printf '%4097s' x >"$FAKE_DASH_STATE/port-control.request"
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "oversized request was accepted"
[ "$(grep -c '^apply-port-settings$' "$FAKE_STACK_LOG")" = 1 ] || fail "invalid request invoked apply"

new_case open
jq '.bitcoin.rpc_expose=false | .monero.rpc_expose=false | .monero.zmq_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
request '{"id":"10101010101010101010101010101010","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.20","host_port":28332},{"port":"monero_zmq","enabled":true,"bind_ip":"10.0.0.20","host_port":28083}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = true ] || fail "Bitcoin RPC was not opened"
[ "$(jq -r '.bitcoin.rpc_bind_ip' "$case_root/config/config.json")" = 192.168.1.20 ] || fail "Bitcoin RPC bind was not saved"
[ "$(jq -r '.bitcoin.rpc_port' "$case_root/config/config.json")" = 28332 ] || fail "Bitcoin RPC port was not saved"
[ "$(jq -r '.monero.zmq_expose' "$case_root/config/config.json")" = true ] || fail "Monero ZMQ was not opened"
[ "$(jq -r '.monero.zmq_bind_ip' "$case_root/config/config.json")" = 10.0.0.20 ] || fail "Monero ZMQ bind was not saved"
[ "$(jq -r '.monero.zmq_port' "$case_root/config/config.json")" = 28083 ] || fail "Monero ZMQ port was not saved"
[ "$(status .state)" = applied ] || fail "successful open status was not applied"
grep -qx apply-port-settings "$FAKE_STACK_LOG" || fail "open did not use the bounded port-settings apply"

new_case change-open-port
request '{"id":"11111111111111111111111111111112","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"172.16.1.20","host_port":38332}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = true ] || fail "editing an open listener closed it"
[ "$(jq -r '.bitcoin.rpc_bind_ip' "$case_root/config/config.json")" = 172.16.1.20 ] || fail "open listener bind edit was not saved"
[ "$(jq -r '.bitcoin.rpc_port' "$case_root/config/config.json")" = 38332 ] || fail "open listener port edit was not saved"
[ "$(status .state)" = applied ] || fail "open listener edit was not applied"

new_case invalid-open
original_config=$(cat "$case_root/config/config.json")
for payload in \
  '{"id":"20202020202020202020202020202020","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"0.0.0.0","host_port":28332}],"requested_at":1000}' \
  '{"id":"21212121212121212121212121212121","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"127.0.0.1","host_port":28332}],"requested_at":1000}' \
  '{"id":"22222222222222222222222222222223","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"8.8.8.8","host_port":28332}],"requested_at":1000}' \
  '{"id":"23232323232323232323232323232323","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.001.20","host_port":28332}],"requested_at":1000}' \
  '{"id":"24242424242424242424242424242424","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"fd00::1","host_port":28332}],"requested_at":1000}' \
  '{"id":"25252525252525252525252525252525","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.20","host_port":0}],"requested_at":1000}' \
  '{"id":"26262626262626262626262626262626","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.20","host_port":"28332"}],"requested_at":1000}' \
  '{"id":"27272727272727272727272727272727","changes":[{"port":"bitcoin_rpc","enabled":false,"bind_ip":"192.168.1.20","host_port":28332}],"requested_at":1000}'; do
  request "$payload"
  scripts/node-port-control
  [ "$(status .state)" = rejected ] || fail "unsafe open request was accepted: $payload"
done
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "invalid open request changed server config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "invalid open request invoked apply"

new_case conflict
jq '.bitcoin.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
request '{"id":"30303030303030303030303030303030","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":18081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "colliding open request was accepted"
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "colliding open request poisoned config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "colliding open request invoked apply"

new_case host-port-conflict
jq '.monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
export FAKE_SS_LISTENERS='LISTEN 0 4096 0.0.0.0:28081 0.0.0.0:*'
original_config=$(cat "$case_root/config/config.json")
request '{"id":"30303030303030303030303030303031","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":28081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "occupied host port was accepted"
[ "$(status .error_code)" = port_in_use ] || fail "occupied host port lacked typed error"
[ "$(status .port)" = monero_rpc ] || fail "occupied host port status named the wrong setting"
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "occupied host port changed config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "occupied host port invoked apply"

if command -v ss >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  new_case real-host-port-conflict
  jq '.monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
  mv "$case_root/config/config.next" "$case_root/config/config.json"
  SS_BIN=$(command -v ss)
  export SS_BIN
  openssl s_server -accept 0.0.0.0:49555 -nocert -quiet -ign_eof </dev/null >"$case_root/listener.log" 2>&1 &
  listener_pid=$!
  listener_ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if "$SS_BIN" -H -ltn | grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*):49555([[:space:]]|$)'; then
      listener_ready=1
      break
    fi
    sleep 0.1
  done
  [ "$listener_ready" = 1 ] || fail "real TCP listener did not start"
  original_config=$(cat "$case_root/config/config.json")
  request '{"id":"30303030303030303030303030303036","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":49555}],"requested_at":1000}'
  scripts/node-port-control
  [ "$(status .error_code)" = port_in_use ] || fail "real host listener lacked typed conflict status"
  [ "$(status .port)" = monero_rpc ] || fail "real host listener named the wrong setting"
  [ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "real host listener changed config"
  [ ! -s "$FAKE_STACK_LOG" ] || fail "real host listener invoked apply"
  kill "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  listener_pid=
fi

new_case docker-port-conflict
jq '.monero.zmq_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
export FAKE_OTHER_DOCKER_IDS=other-id
export FAKE_OTHER_PORTS='{"28083/tcp":[{"HostIp":"0.0.0.0","HostPort":"28083"}]}'
original_config=$(cat "$case_root/config/config.json")
request '{"id":"30303030303030303030303030303032","changes":[{"port":"monero_zmq","enabled":true,"bind_ip":"192.168.1.10","host_port":28083}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .error_code)" = port_in_use ] || fail "other Docker port lacked typed conflict status"
[ "$(status .port)" = monero_zmq ] || fail "other Docker conflict named the wrong setting"
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "other Docker conflict changed config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "other Docker conflict invoked apply"

new_case mapped-ipv6-conflict
jq '.monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
export FAKE_SS_LISTENERS='LISTEN 0 4096 [::ffff:192.168.1.10]:28081 [::]:*'
original_config=$(cat "$case_root/config/config.json")
request '{"id":"30303030303030303030303030303037","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":28081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .error_code)" = port_in_use ] || fail "IPv4-mapped IPv6 listener was missed"
[ "$(status .port)" = monero_rpc ] || fail "IPv4-mapped listener named the wrong setting"
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "IPv4-mapped listener changed config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "IPv4-mapped listener invoked apply"

new_case own-port-swap
export FAKE_SS_LISTENERS='LISTEN 0 4096 192.168.1.10:8332 0.0.0.0:*'
request '{"id":"30303030303030303030303030303033","changes":[{"port":"bitcoin_rpc","enabled":false},{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":8332}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = applied ] || fail "own Tor listener prevented a port swap"
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "port swap did not close Bitcoin RPC"
[ "$(jq -r '.monero.rpc_port' "$case_root/config/config.json")" = 8332 ] || fail "port swap did not move Monero RPC"

new_case inspection-failure
jq '.monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
export FAKE_SS_FAIL=1
original_config=$(cat "$case_root/config/config.json")
request '{"id":"30303030303030303030303030303034","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":28081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = failed ] || fail "listener inspection failure did not fail safely"
[ "$(status .error_code)" = port_check_failed ] || fail "listener inspection failure lacked typed status"
[ "$(status 'has("port")')" = false ] || fail "listener inspection failure included a misleading port"
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "inspection failure changed config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "inspection failure invoked apply"

new_case wrong-tor
jq '.monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
export FAKE_TOR_CONFIG_FILES=/another/install/docker-compose.yml
original_config=$(cat "$case_root/config/config.json")
request '{"id":"30303030303030303030303030303035","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.10","host_port":28081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .error_code)" = port_check_failed ] || fail "unrelated Tor container was trusted"
[ "$(cat "$case_root/config/config.json")" = "$original_config" ] || fail "unrelated Tor container changed config"
[ ! -s "$FAKE_STACK_LOG" ] || fail "unrelated Tor container invoked apply"

new_case disabled-node
jq '.monero.enabled=false | .monero.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
request '{"id":"31313131313131313131313131313131","changes":[{"port":"monero_rpc","enabled":true,"bind_ip":"192.168.1.20","host_port":28081}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "disabled node listener was opened"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = false ] || fail "disabled node request poisoned config"

new_case weak-credentials
jq '.bitcoin.rpc_expose=false | .bitcoin.node_password="short"' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
request '{"id":"32323232323232323232323232323232","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.20","host_port":28332}],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "listener with weak saved credentials was opened"
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "weak-credential request poisoned config"

new_case weak-credentials-close
jq '.bitcoin.node_password="short"' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
request '{"id":"33333333333333333333333333333334","changes":[{"port":"bitcoin_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "weak credentials prevented reducing exposure"
[ "$(status .state)" = applied ] || fail "safe close with weak credentials was rejected"

new_case generated-credentials
jq 'del(.bitcoin.node_password) | .bitcoin.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
printf '%s\n' 'BITCOIN_RPC_PASSWORD=generatedpassword123456789012345678' >>"$case_root/state/.env"
request '{"id":"34343434343434343434343434343434","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.30","host_port":58332}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = true ] || fail "generated saved credential could not open Bitcoin RPC"
[ "$(status .state)" = applied ] || fail "generated saved credential request was rejected"
grep -q generatedpassword "$FAKE_DOCKER_LOG" "$FAKE_STACK_LOG" && fail "generated RPC credential leaked into command logs"

new_case concurrent-edit
real_cmp=$(command -v cmp)
mkdir -p "$case_root/bin"
cat >"$case_root/bin/cmp" <<'EOF'
#!/bin/sh
set -eu
if [ ! -e "$CAS_EDIT_MARKER" ]; then
  jq '.dashboard.password="changedconcurrently1234567890" | .monero.rpc_expose=false | .other.concurrent="preserved"' "$CAS_CONFIG" >"$CAS_CONFIG.next"
  mv "$CAS_CONFIG.next" "$CAS_CONFIG"
  : >"$CAS_EDIT_MARKER"
fi
exec "$REAL_CMP" "$@"
EOF
chmod +x "$case_root/bin/cmp"
export REAL_CMP=$real_cmp CAS_CONFIG=$case_root/config/config.json CAS_EDIT_MARKER=$case_root/cas-edited
saved_path=$PATH
PATH=$case_root/bin:$PATH
request '{"id":"12121212121212121212121212121212","changes":[{"port":"bitcoin_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
PATH=$saved_path
unset REAL_CMP CAS_CONFIG CAS_EDIT_MARKER
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "concurrent edit retry did not close requested port"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = false ] || fail "concurrent port closure was reverted"
[ "$(jq -r '.dashboard.password' "$case_root/config/config.json")" = changedconcurrently1234567890 ] || fail "concurrent password edit was reverted"
[ "$(jq -r '.other.concurrent' "$case_root/config/config.json")" = preserved ] || fail "concurrent unrelated edit was reverted"
[ "$(grep -c '^apply-port-settings$' "$FAKE_STACK_LOG")" = 1 ] || fail "concurrent edit retry invoked apply more than once"

new_case interrupted
mkdir -p "$case_root/state/port-control"
printf '%s\n' 88888888888888888888888888888888 >"$case_root/state/port-control/inflight"
jq '.bitcoin.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
printf '%s\n' '{"id":"88888888888888888888888888888888","changes":[{"port":"bitcoin_rpc","enabled":false}],"requested_at":1000}' >"$FAKE_DASH_STATE/port-control.processing"
scripts/node-port-control
[ "$(status .state)" = applied ] || fail "interrupted close was not resumed"
grep -qx apply-port-settings "$FAKE_STACK_LOG" || fail "interrupted close did not retry apply"

new_case interrupted-before-commit
mkdir -p "$case_root/state/port-control"
printf '%s\n' 89898989898989898989898989898989 >"$case_root/state/port-control/inflight"
printf '%s\n' '{"id":"89898989898989898989898989898989","changes":[{"port":"bitcoin_rpc","enabled":false},{"port":"monero_zmq","enabled":false}],"requested_at":1000}' >"$FAKE_DASH_STATE/port-control.processing"
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "pre-commit recovery left Bitcoin RPC open"
[ "$(jq -r '.monero.zmq_expose' "$case_root/config/config.json")" = false ] || fail "pre-commit recovery left Monero ZMQ open"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = true ] || fail "pre-commit recovery changed an unrequested port"
[ "$(status .state)" = applied ] || fail "pre-commit recovery was not applied"
grep -qx apply-port-settings "$FAKE_STACK_LOG" || fail "pre-commit recovery did not invoke apply"

new_case guard
export FAKE_CONFIG_FILES=/another/install/docker-compose.yml
request '{"id":"66666666666666666666666666666666","changes":[{"port":"bitcoin_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = true ] || fail "wrong-stack guard changed config"
[ ! -e "$FAKE_DASH_STATE/port-control.capability" ] || fail "wrong-stack dashboard received a capability"
[ ! -s "$FAKE_STACK_LOG" ] || fail "wrong-stack dashboard invoked apply"

new_case no-password
sed -i.bak 's/DASHBOARD_PASSWORD=.*/DASHBOARD_PASSWORD=/' "$case_root/state/.env"
: >"$FAKE_DASH_STATE/port-control.capability"
scripts/node-port-control
[ ! -e "$FAKE_DASH_STATE/port-control.capability" ] || fail "passwordless dashboard retained a capability"

new_case apply-failure
export FAKE_APPLY_FAIL_ONCE=1
request '{"id":"77777777777777777777777777777777","changes":[{"port":"monero_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = true ] || fail "failed apply did not restore the prior config"
[ "$(status .state)" = failed ] || fail "failed apply status was not recorded"
request '{"id":"78787878787878787878787878787878","changes":[{"port":"monero_rpc","enabled":false}],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = false ] || fail "port change could not be retried after rollback"
[ "$(status .state)" = applied ] || fail "retried port change was not applied"

new_case actual-stack
cp stack configure.sh docker-compose.yml docker-compose.rpc.yml docker-compose.monero-rpc.yml docker-compose.monero-zmq.yml "$case_root/root/"
printf '1.2.3\n' >"$case_root/root/VERSION"
: >"$FAKE_DOCKER_LOG"
request '{"id":"91919191919191919191919191919191","changes":[{"port":"bitcoin_rpc","enabled":false}],"requested_at":1000}'
saved_path=$PATH
PATH=$tmp:$PATH
scripts/node-port-control
PATH=$saved_path
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "actual stack close did not persist"
grep -q 'compose .*up -d --pull never --no-build --no-deps tor dashboard' "$FAKE_DOCKER_LOG" ||
  fail "actual stack close did not target only Tor and dashboard"
: >"$FAKE_DOCKER_LOG"
request '{"id":"92929292929292929292929292929292","changes":[{"port":"bitcoin_rpc","enabled":true,"bind_ip":"192.168.1.25","host_port":48332}],"requested_at":1000}'
PATH=$tmp:$PATH
scripts/node-port-control
PATH=$saved_path
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = true ] || fail "actual stack open did not persist"
[ "$(jq -r '.bitcoin.rpc_bind_ip' "$case_root/config/config.json")" = 192.168.1.25 ] || fail "actual stack open lost its bind"
[ "$(jq -r '.bitcoin.rpc_port' "$case_root/config/config.json")" = 48332 ] || fail "actual stack open lost its port"
grep -q 'compose .*up -d --pull never --no-build --no-deps tor dashboard' "$FAKE_DOCKER_LOG" ||
  fail "actual stack open did not target only Tor and dashboard"

grep -q '^ProtectSystem=strict$' packaging/systemd/bitcoin-starter-stack-port-control.service || fail "systemd service is not filesystem-hardened"
grep -q '^RestrictAddressFamilies=AF_UNIX AF_NETLINK$' packaging/systemd/bitcoin-starter-stack-port-control.service ||
  fail "systemd service lacks its restricted Unix and socket-diagnostic families"
grep -q '^Persistent=true$' packaging/systemd/bitcoin-starter-stack-port-control.timer || fail "systemd timer does not catch up after reboot"

echo "PASS: test_port_control.sh"
