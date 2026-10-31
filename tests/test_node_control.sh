#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $1"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
root=$tmp/root
state=$tmp/state
config=$tmp/config
dashboard_state=$tmp/dashboard
mkdir -p "$root/scripts" "$state" "$config" "$dashboard_state"
cp scripts/node-control "$root/scripts/"
: >"$root/docker-compose.yml"
cat >"$root/configure.sh" <<'EOF'
#!/bin/sh
set -eu
jq -e 'type=="object"' "$BITCOIN_STACK_CONFIG_DIR/config.json" >/dev/null
if [ "${BITCOIN_STACK_VALIDATE_ONLY:-0}" != 1 ]; then
  if [ "${FAKE_CONFIGURE_FAIL_ONCE:-0}" = 1 ] && [ ! -e "$FAKE_CONFIGURE_FAIL_MARKER" ]; then
    : >"$FAKE_CONFIGURE_FAIL_MARKER"
    exit 1
  fi
  printf 'DASHBOARD_PASSWORD=testpassword\n' >"$BITCOIN_STACK_STATE_DIR/.env"
fi
EOF
cat >"$root/stack" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STACK_LOG"
[ "${FAKE_STACK_FAIL_ONCE:-0}" != 1 ] || {
  if [ ! -e "$FAKE_STACK_FAIL_MARKER" ]; then
    : >"$FAKE_STACK_FAIL_MARKER"
    exit 1
  fi
}
[ "${FAKE_STACK_FAIL:-0}" != 1 ]
EOF
chmod +x "$root/configure.sh" "$root/stack" "$root/scripts/node-control"
cat >"$tmp/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = inspect ]; then
  case "$3" in
    '{{.Id}}') printf 'dashboard-id\n' ;;
    *project.config_files*) printf '%s/docker-compose.yml\n' "$BITCOIN_STACK_ROOT" ;;
  esac
  exit 0
fi
[ "$1" = exec ] || exit 1
shift
[ "${1:-}" != -i ] || shift
if [ "${1:-}" = -u ]; then shift 2; fi
[ "$1" = dashboard ]
shift
if [ "$1" = sh ] && [ "$2" = -c ]; then
  command=${3//\/state/$FAKE_DASH_STATE}
  exec sh -c "$command"
fi
args=()
for arg in "$@"; do args+=("${arg//\/state/$FAKE_DASH_STATE}"); done
exec "${args[@]}"
EOF
chmod +x "$tmp/docker"
cat >"$config/config.json" <<'EOF'
{"bitcoin":{"enabled":true,"active":true},"monero":{"enabled":true,"active":true},"tari":{"enabled":true,"active":true},"litecoin":{"enabled":false},"dogecoin":{"enabled":false},"bitcoincash":{"enabled":false}}
EOF
printf 'DASHBOARD_PASSWORD=testpassword\n' >"$state/.env"
export BITCOIN_STACK_ROOT=$root BITCOIN_STACK_STATE_DIR=$state BITCOIN_STACK_CONFIG_DIR=$config
export DOCKER_BIN=$tmp/docker FAKE_DASH_STATE=$dashboard_state FAKE_STACK_LOG=$tmp/stack.log NODE_CONTROL_NOW_EPOCH=1000
export FAKE_STACK_FAIL_ONCE=0 FAKE_STACK_FAIL_MARKER=$tmp/stack-failed
export FAKE_CONFIGURE_FAIL_ONCE=0 FAKE_CONFIGURE_FAIL_MARKER=$tmp/configure-failed

request() { printf '%s\n' "$1" >"$dashboard_state/node-control.request"; }
status() { jq -r "$1" "$dashboard_state/node-control.status"; }

request '{"id":"11111111111111111111111111111111","node":"tari","active":false,"confirmation":"deactivate","requested_at":1000}'
"$root/scripts/node-control"
[ "$(jq -r .tari.active "$config/config.json")" = false ] || fail "Tari was not deactivated"
grep -qx 'stop tari-wallet tari' "$tmp/stack.log" || fail "Tari wallet was not stopped before its node"
[ "$(status .state)" = applied ] || fail "deactivation status was not applied"
[ "$(jq -r '.bitcoin,.monero,.tari' "$dashboard_state/node-runtime.json" | tr '\n' ' ')" = 'true true false ' ] || fail "runtime state map is wrong"
if [ "$(uname -s)" = Darwin ]; then
  runtime_mode=$(stat -f %Lp "$dashboard_state/node-runtime.json")
else
  runtime_mode=$(stat -c %a "$dashboard_state/node-runtime.json")
fi
[ "$runtime_mode" = 600 ] || fail "runtime state is not private"

request '{"id":"22222222222222222222222222222222","node":"tari","active":true,"confirmation":"","requested_at":1000}'
"$root/scripts/node-control"
[ "$(jq -r .tari.active "$config/config.json")" = true ] || fail "Tari was not reactivated"
grep -qx 'up tari tari-wallet' "$tmp/stack.log" || fail "Tari node was not started before its wallet"

request '{"id":"22222222222222222222222222222222","node":"tari","active":false,"confirmation":"deactivate","requested_at":1000}'
"$root/scripts/node-control"
[ "$(status .error_code)" = replayed ] || fail "replayed request was accepted"

request '{"id":"33333333333333333333333333333333","node":"litecoin","active":false,"confirmation":"deactivate","requested_at":1000}'
"$root/scripts/node-control"
[ "$(status .error_code)" = node_not_configured ] || fail "disabled node was changed"

printf '%2049s' x >"$dashboard_state/node-control.request"
"$root/scripts/node-control"
[ "$(status .error_code)" = invalid_request ] || fail "oversized request was not rejected"
[ ! -e "$dashboard_state/node-control.processing" ] || fail "oversized request remained stuck"

request '{"id":"44444444444444444444444444444444","node":"monero","active":false,"confirmation":"deactivate","requested_at":1000}'
FAKE_STACK_FAIL_ONCE=1 "$root/scripts/node-control"
[ "$(jq -r .monero.active "$config/config.json")" = true ] || fail "failed apply did not restore config"
[ "$(status .error_code)" = apply_failed ] || fail "failed apply lacked typed status"
tail -n 2 "$tmp/stack.log" | grep -qx 'stop monero-wallet monero' || fail "failed Monero apply was not attempted"
tail -n 2 "$tmp/stack.log" | grep -qx 'up monero monero-wallet' || fail "partial Monero stop was not restored"

request '{"id":"45454545454545454545454545454545","node":"bitcoin","active":false,"confirmation":"deactivate","requested_at":1000}'
FAKE_CONFIGURE_FAIL_ONCE=1 "$root/scripts/node-control"
[ "$(jq -r .bitcoin.active "$config/config.json")" = true ] || fail "failed render did not restore config"
[ "$(status .error_code)" = apply_failed ] || fail "failed render lacked typed status"
! grep -q '^stop bitcoin$' "$tmp/stack.log" || fail "failed render changed a service"

printf 'DASHBOARD_PASSWORD=\n' >"$state/.env"
rm -f "$dashboard_state/node-control.capability"
request '{"id":"55555555555555555555555555555555","node":"bitcoin","active":false,"confirmation":"deactivate","requested_at":1000}'
"$root/scripts/node-control"
[ ! -e "$dashboard_state/node-control.capability" ] || fail "control enabled without dashboard authentication"
[ "$(jq -r .bitcoin.active "$config/config.json")" = true ] || fail "unauthenticated request changed config"
rm -f "$dashboard_state/node-control.request"
printf '%s\n' '{"version":1,"iterations":210000,"salt":"0123456789abcdef0123456789abcdef","hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' >"$dashboard_state/dashboard_auth.json"
"$root/scripts/node-control"
[ "$(cat "$dashboard_state/node-control.capability")" = ready ] || fail "saved dashboard authentication did not enable node control"
printf '%s\n' '{"version":1,"iterations":210000,"salt":"bad","hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' >"$dashboard_state/dashboard_auth.json"
"$root/scripts/node-control"
[ ! -e "$dashboard_state/node-control.capability" ] || fail "malformed saved dashboard authentication enabled node control"

echo "PASS: test_node_control.sh"
