#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/docker
cat >"$fake" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "$1" = inspect ]; then
  case "$3" in
    '{{.Id}}') printf '%s\n' dashboard-id ;;
    *project.config_files*) printf '%s\n' "${FAKE_CONFIG_FILES:-$BITCOIN_STACK_ROOT/docker-compose.yml}" ;;
  esac
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

new_case() {
  case_root=$tmp/$1
  mkdir -p "$case_root/root/scripts" "$case_root/state/dashboard" "$case_root/config"
  cp scripts/node-port-control "$case_root/root/scripts/"
  : >"$case_root/root/docker-compose.yml"
  cat >"$case_root/root/stack" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STACK_LOG"
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
{"bitcoin":{"rpc_expose":true,"rpc_bind_ip":"192.168.1.10","steady_cpus":0.5},"monero":{"rpc_expose":true,"zmq_expose":true,"rpc_port":18081},"dashboard":{"password":"testpassword"},"other":{"keep":"yes"}}
EOF
  export BITCOIN_STACK_ROOT=$case_root/root
  export BITCOIN_STACK_STATE_DIR=$case_root/state
  export BITCOIN_STACK_CONFIG_DIR=$case_root/config
  export DOCKER_BIN=$fake FAKE_DASH_STATE=$case_root/state/dashboard
  export FAKE_DOCKER_LOG=$case_root/docker.log FAKE_STACK_LOG=$case_root/stack.log
  export PORT_CONTROL_NOW_EPOCH=1000 FAKE_APPLY_FAIL=0
  unset FAKE_CONFIG_FILES
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
request '{"id":"11111111111111111111111111111111","ports":["bitcoin_rpc","monero_zmq"],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "Bitcoin RPC remained enabled"
[ "$(jq -r '.monero.zmq_expose' "$case_root/config/config.json")" = false ] || fail "Monero ZMQ remained enabled"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = true ] || fail "unrequested Monero RPC changed"
[ "$(jq -r '.other.keep' "$case_root/config/config.json")" = yes ] || fail "unrelated config changed"
[ "$(stat -c %a "$case_root/config/config.json" 2>/dev/null || stat -f %Lp "$case_root/config/config.json")" = 600 ] || fail "config permissions are not private"
[ "$(status .state)" = applied ] || fail "successful close status was not applied"
grep -qx apply "$FAKE_STACK_LOG" || fail "close did not use offline stack apply"
grep -q pull "$FAKE_STACK_LOG" && fail "close attempted an image download"
grep -q testpassword "$FAKE_DOCKER_LOG" "$FAKE_STACK_LOG" && fail "close leaked a credential into command logs"
[ ! -e "$FAKE_DASH_STATE/port-control.request" ] && [ ! -e "$FAKE_DASH_STATE/port-control.processing" ] || fail "request was not consumed"
[ "$(cat "$FAKE_DASH_STATE/port-control.capability")" = ready ] || fail "capability heartbeat missing"

request '{"id":"11111111111111111111111111111111","ports":["monero_rpc"],"requested_at":1000}'
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "replayed request was accepted"
[ "$(grep -c '^apply$' "$FAKE_STACK_LOG")" = 1 ] || fail "replay invoked apply"

for payload in \
  '{"id":"22222222222222222222222222222222","ports":["unknown"],"requested_at":1000}' \
  '{"id":"33333333333333333333333333333333","ports":["monero_rpc","monero_rpc"],"requested_at":1000}' \
  '{"id":"44444444444444444444444444444444","ports":["monero_rpc"],"requested_at":699}' \
  '{"id":"55555555555555555555555555555555","ports":["monero_rpc"],"requested_at":1000,"extra":true}' \
  'not-json'; do
  request "$payload"
  scripts/node-port-control
  [ "$(status .state)" = rejected ] || fail "invalid request was accepted: $payload"
done
printf '%4097s' x >"$FAKE_DASH_STATE/port-control.request"
scripts/node-port-control
[ "$(status .state)" = rejected ] || fail "oversized request was accepted"
[ "$(grep -c '^apply$' "$FAKE_STACK_LOG")" = 1 ] || fail "invalid request invoked apply"

new_case concurrent-edit
real_cmp=$(command -v cmp)
mkdir -p "$case_root/bin"
cat >"$case_root/bin/cmp" <<'EOF'
#!/bin/sh
set -eu
if [ ! -e "$CAS_EDIT_MARKER" ]; then
  jq '.dashboard.password="changed-concurrently" | .monero.rpc_expose=false | .other.concurrent="preserved"' "$CAS_CONFIG" >"$CAS_CONFIG.next"
  mv "$CAS_CONFIG.next" "$CAS_CONFIG"
  : >"$CAS_EDIT_MARKER"
fi
exec "$REAL_CMP" "$@"
EOF
chmod +x "$case_root/bin/cmp"
export REAL_CMP=$real_cmp CAS_CONFIG=$case_root/config/config.json CAS_EDIT_MARKER=$case_root/cas-edited
saved_path=$PATH
PATH=$case_root/bin:$PATH
request '{"id":"12121212121212121212121212121212","ports":["bitcoin_rpc"],"requested_at":1000}'
scripts/node-port-control
PATH=$saved_path
unset REAL_CMP CAS_CONFIG CAS_EDIT_MARKER
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "concurrent edit retry did not close requested port"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = false ] || fail "concurrent port closure was reverted"
[ "$(jq -r '.dashboard.password' "$case_root/config/config.json")" = changed-concurrently ] || fail "concurrent password edit was reverted"
[ "$(jq -r '.other.concurrent' "$case_root/config/config.json")" = preserved ] || fail "concurrent unrelated edit was reverted"
[ "$(grep -c '^apply$' "$FAKE_STACK_LOG")" = 1 ] || fail "concurrent edit retry invoked apply more than once"

new_case interrupted
mkdir -p "$case_root/state/port-control"
printf '%s\n' 88888888888888888888888888888888 >"$case_root/state/port-control/inflight"
jq '.bitcoin.rpc_expose=false' "$case_root/config/config.json" >"$case_root/config/config.next"
mv "$case_root/config/config.next" "$case_root/config/config.json"
printf '%s\n' '{"id":"88888888888888888888888888888888","ports":["bitcoin_rpc"],"requested_at":1000}' >"$FAKE_DASH_STATE/port-control.processing"
scripts/node-port-control
[ "$(status .state)" = applied ] || fail "interrupted close was not resumed"
grep -qx apply "$FAKE_STACK_LOG" || fail "interrupted close did not retry apply"

new_case interrupted-before-commit
mkdir -p "$case_root/state/port-control"
printf '%s\n' 89898989898989898989898989898989 >"$case_root/state/port-control/inflight"
printf '%s\n' '{"id":"89898989898989898989898989898989","ports":["bitcoin_rpc","monero_zmq"],"requested_at":1000}' >"$FAKE_DASH_STATE/port-control.processing"
scripts/node-port-control
[ "$(jq -r '.bitcoin.rpc_expose' "$case_root/config/config.json")" = false ] || fail "pre-commit recovery left Bitcoin RPC open"
[ "$(jq -r '.monero.zmq_expose' "$case_root/config/config.json")" = false ] || fail "pre-commit recovery left Monero ZMQ open"
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = true ] || fail "pre-commit recovery changed an unrequested port"
[ "$(status .state)" = applied ] || fail "pre-commit recovery was not applied"
grep -qx apply "$FAKE_STACK_LOG" || fail "pre-commit recovery did not invoke apply"

new_case guard
export FAKE_CONFIG_FILES=/another/install/docker-compose.yml
request '{"id":"66666666666666666666666666666666","ports":["bitcoin_rpc"],"requested_at":1000}'
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
export FAKE_APPLY_FAIL=1
request '{"id":"77777777777777777777777777777777","ports":["monero_rpc"],"requested_at":1000}'
scripts/node-port-control
[ "$(jq -r '.monero.rpc_expose' "$case_root/config/config.json")" = false ] || fail "failed apply did not preserve desired closed state"
[ "$(status .state)" = failed ] || fail "failed apply status was not recorded"

grep -q '^ProtectSystem=strict$' packaging/systemd/bitcoin-starter-stack-port-control.service || fail "systemd service is not filesystem-hardened"
grep -q '^RestrictAddressFamilies=AF_UNIX$' packaging/systemd/bitcoin-starter-stack-port-control.service || fail "systemd service can use public network sockets"
grep -q '^Persistent=true$' packaging/systemd/bitcoin-starter-stack-port-control.timer || fail "systemd timer does not catch up after reboot"

echo "PASS: test_port_control.sh"
