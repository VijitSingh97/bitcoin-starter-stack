#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/fake-docker
log=$tmp/docker.log
caps=$tmp/caps
mkdir "$caps"

cat >"$fake" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"

if [ "$1" = compose ]; then
  shift
  while [ "$1" != ps ] && [ "$1" != exec ] && [ "$1" != stop ] && [ "$1" != start ]; do shift; done
  command=$1
  shift
  case "$command" in
    ps)
      [ "$1" = -q ]
      case "$2" in
        bitcoin) [ "${FAKE_BITCOIN_RUNNING:-1}" = 1 ] && printf '%s\n' "${FAKE_BITCOIN_ID:-btc-id}" ;;
        monero) [ "${FAKE_MONERO_RUNNING:-1}" = 1 ] && printf '%s\n' "${FAKE_MONERO_ID:-xmr-id}" ;;
      esac
      ;;
    exec)
      [ "$1" = -T ]
      case "$2" in
        bitcoin)
          if [ "${FAKE_BITCOIN_RPC_FAIL:-0}" = 1 ]; then exit 1; fi
          if [ "${FAKE_BITCOIN_SYNCED:-0}" = 1 ]; then
            printf '%s\n' "{\"initialblockdownload\":false,\"blocks\":100,\"headers\":100,\"time\":${FAKE_BITCOIN_TIP:-$RESOURCE_NOW_EPOCH},\"warnings\":${FAKE_BITCOIN_WARNINGS:-[]}}"
          else
            printf '%s\n' "{\"initialblockdownload\":true,\"blocks\":50,\"headers\":100,\"time\":${RESOURCE_NOW_EPOCH},\"warnings\":[]}"
          fi
          ;;
        monero)
          if [ "${FAKE_MONERO_RPC_FAIL:-0}" = 1 ]; then exit 1; fi
          if [ "${FAKE_MONERO_SYNCED:-0}" = 1 ]; then
            printf '%s\n' '{"result":{"status":"OK","synchronized":true,"busy_syncing":false,"height":100,"target_height":100}}'
            printf '%s\n' "{\"result\":{\"status\":\"OK\",\"block_header\":{\"timestamp\":${FAKE_MONERO_TIP:-$RESOURCE_NOW_EPOCH}}}}"
          else
            printf '%s\n' '{"result":{"status":"OK","synchronized":false,"busy_syncing":true,"height":50,"target_height":100}}'
            printf '%s\n' "{\"result\":{\"status\":\"OK\",\"block_header\":{\"timestamp\":${RESOURCE_NOW_EPOCH}}}}"
          fi
          ;;
      esac
      ;;
    stop | start) exit 0 ;;
  esac
  exit 0
fi

case "$1" in
  inspect)
    id=${4:-}
    case "$3" in
      *State.Health*)
        case "$id" in
          btc-*) printf '%s\n' "${FAKE_BITCOIN_HEALTH:-healthy}" ;;
          xmr-*) printf '%s\n' "${FAKE_MONERO_HEALTH:-healthy}" ;;
          *) printf '%s\n' healthy ;;
        esac
        ;;
      *HostConfig*)
        case "$id" in
          btc-*) configured=${FAKE_BITCOIN_LIMITS:-} ;;
          xmr-*) configured=${FAKE_MONERO_LIMITS:-} ;;
          *) configured= ;;
        esac
        if [ -n "$configured" ]; then
          printf '%s\n' "$configured"
        elif [ -f "$FAKE_CAPS/$id" ]; then
          printf '%s\n' '1000000000 2147483648 2147483648'
        else
          printf '%s\n' '0 0 0'
        fi
        ;;
      *State.ExitCode*) printf '%s\n' "${FAKE_EXIT_CODE:-0}" ;;
    esac
    ;;
  stats)
    id=$5
    case "$id" in
      btc-*) printf '%s\n' "${FAKE_BITCOIN_MEMORY:-700MiB} / 8GiB" ;;
      xmr-*) printf '%s\n' "${FAKE_MONERO_MEMORY:-600MiB} / 8GiB" ;;
    esac
    ;;
  update)
    id=$8
    [ "${FAKE_UPDATE_FAIL:-0}" != 1 ] && : >"$FAKE_CAPS/$id"
    ;;
esac
EOF
chmod +x "$fake" scripts/node-resource-profile tests/test_resource_profile.sh

new_case() {
  case_root=$tmp/$1
  mkdir -p "$case_root/root" "$case_root/state"
  : >"$case_root/root/docker-compose.yml"
  : >"$log"
  rm -f "$caps"/*
  cat >"$case_root/state/.env" <<'EOF'
BITCOIN_RESOURCE_PROFILE=off
MONERO_RESOURCE_PROFILE=off
BITCOIN_DBCACHE=128
EOF
  export BITCOIN_STACK_ROOT=$case_root/root
  export BITCOIN_STACK_STATE_DIR=$case_root/state
  export DOCKER_BIN=$fake FAKE_DOCKER_LOG=$log FAKE_CAPS=$caps
  export FAKE_BITCOIN_ID=btc-id FAKE_MONERO_ID=xmr-id
  export FAKE_BITCOIN_RUNNING=1 FAKE_MONERO_RUNNING=1
  export FAKE_BITCOIN_SYNCED=0 FAKE_MONERO_SYNCED=0
  export FAKE_BITCOIN_HEALTH=healthy FAKE_MONERO_HEALTH=healthy
  export FAKE_BITCOIN_MEMORY=700MiB FAKE_MONERO_MEMORY=600MiB
  export FAKE_BITCOIN_RPC_FAIL=0 FAKE_MONERO_RPC_FAIL=0 FAKE_UPDATE_FAIL=0
  export FAKE_BITCOIN_LIMITS='' FAKE_MONERO_LIMITS='' FAKE_EXIT_CODE=0
  unset FAKE_BITCOIN_TIP FAKE_BITCOIN_WARNINGS FAKE_MONERO_TIP
  export RESOURCE_NOW_EPOCH=100000
}

run_profile() {
  scripts/node-resource-profile
}

tick_profile() {
  RESOURCE_NOW_EPOCH=$((RESOURCE_NOW_EPOCH + 60))
  export RESOURCE_NOW_EPOCH
  run_profile
}

new_case disabled
run_profile
[ ! -s "$log" ] || fail "disabled profiles invoked Docker"

new_case bitcoin-sync
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
tick_profile
tick_profile
tick_profile
! grep -q '^update ' "$log" || fail "syncing Bitcoin was capped"
[ "$(cut -d '|' -f 1-3 "$case_root/state/resource-profile/bitcoin")" = 'btc-id|0|pending' ] || fail "syncing Bitcoin did not reset stability"

export FAKE_BITCOIN_SYNCED=1
run_profile
run_profile
run_profile
! grep -q '^update ' "$log" || fail "immediate Bitcoin checks counted as sustained readiness"
tick_profile
! grep -q '^update ' "$log" || fail "Bitcoin was capped before three stable checks"
tick_profile
grep -q '^update --cpus 1 --memory 2048m --memory-swap 2048m btc-id$' "$log" || fail "Bitcoin cap is wrong"
[ "$(cut -d '|' -f 1-3 "$case_root/state/resource-profile/bitcoin")" = 'btc-id|3|capped' ] || fail "Bitcoin capped state was not saved"
updates=$(grep -c '^update ' "$log")
tick_profile
[ "$(grep -c '^update ' "$log")" = "$updates" ] || fail "an already capped Bitcoin container was updated again"

new_case recreate
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1
tick_profile; tick_profile; tick_profile
export FAKE_BITCOIN_ID=btc-new
tick_profile; tick_profile
[ "$(grep -c '^update ' "$log")" = 1 ] || fail "recreated Bitcoin was capped before stability checks"
tick_profile
grep -q '^update --cpus 1 --memory 2048m --memory-swap 2048m btc-new$' "$log" || fail "recreated Bitcoin was not capped"

new_case unhealthy
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1 FAKE_BITCOIN_HEALTH=unhealthy
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "unhealthy Bitcoin was capped"

new_case cache
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/; s/BITCOIN_DBCACHE=128/BITCOIN_DBCACHE=1024/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "high-dbcache Bitcoin was capped"
! grep -q ' restart bitcoin$' "$log" || fail "high-dbcache Bitcoin was restarted"
grep -q '|blocked|' "$case_root/state/resource-profile/bitcoin" || fail "high-dbcache Bitcoin was not marked blocked"

new_case memory
perl -pi -e 's/MONERO_RESOURCE_PROFILE=off/MONERO_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_MONERO_SYNCED=1 FAKE_MONERO_MEMORY=1900MiB
tick_profile; tick_profile; tick_profile
[ "$(grep -c ' stop monero$' "$log")" = 1 ] || fail "high-memory Monero did not stop once"
grep -q ' start monero$' "$log" || fail "high-memory Monero was not restarted"
tick_profile; tick_profile; tick_profile
[ "$(grep -c ' stop monero$' "$log")" = 1 ] || fail "high-memory Monero restarted more than once"
! grep -q '^update ' "$log" || fail "high-memory Monero was capped"
grep -q '|blocked|' "$case_root/state/resource-profile/monero" || fail "high-memory Monero was not marked blocked"
export FAKE_MONERO_MEMORY=600MiB
tick_profile
grep -q '^update --cpus 1 --memory 2048m --memory-swap 2048m xmr-id$' "$log" || fail "Monero was not capped after memory became safe"

new_case rpc-failure
perl -pi -e 's/MONERO_RESOURCE_PROFILE=off/MONERO_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_MONERO_SYNCED=1 FAKE_MONERO_RPC_FAIL=1
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "Monero was capped after RPC failures"

new_case stale-tip
perl -pi -e 's/MONERO_RESOURCE_PROFILE=off/MONERO_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_MONERO_SYNCED=1 FAKE_MONERO_TIP=1
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "Monero with a stale tip was capped"

new_case warning
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1 FAKE_BITCOIN_WARNINGS='["test warning"]'
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "Bitcoin reporting a warning was capped"

new_case update-failure
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1 FAKE_UPDATE_FAIL=1
tick_profile; tick_profile
if tick_profile >/dev/null 2>&1; then
  fail "an unverified Docker update was accepted"
fi

new_case existing-limit
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1 FAKE_BITCOIN_LIMITS='500000000 1073741824 1073741824'
tick_profile; tick_profile; tick_profile
! grep -q '^update ' "$log" || fail "an operator-set lower limit was increased"
grep -q '|blocked|' "$case_root/state/resource-profile/bitcoin" || fail "operator-set limits were not marked blocked"

new_case memory-units
perl -pi -e 's/BITCOIN_RESOURCE_PROFILE=off/BITCOIN_RESOURCE_PROFILE=compact/; s/MONERO_RESOURCE_PROFILE=off/MONERO_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_BITCOIN_SYNCED=1 FAKE_MONERO_SYNCED=1
export FAKE_BITCOIN_MEMORY=1073741824B FAKE_MONERO_MEMORY=1048576KiB
tick_profile; tick_profile; tick_profile
grep -q '^update --cpus 1 --memory 2048m --memory-swap 2048m btc-id$' "$log" || fail "byte memory usage was parsed incorrectly"
grep -q '^update --cpus 1 --memory 2048m --memory-swap 2048m xmr-id$' "$log" || fail "KiB memory usage was parsed incorrectly"

new_case dirty-stop
perl -pi -e 's/MONERO_RESOURCE_PROFILE=off/MONERO_RESOURCE_PROFILE=compact/' "$case_root/state/.env"
export FAKE_MONERO_SYNCED=1 FAKE_MONERO_MEMORY=1900MiB FAKE_EXIT_CODE=137
tick_profile; tick_profile; tick_profile
grep -q ' stop monero$' "$log" || fail "high-memory Monero was not stopped"
grep -q ' start monero$' "$log" || fail "Monero was not restarted after a dirty stop"
! grep -q '^update ' "$log" || fail "Monero was capped after a dirty stop"
grep -q '|blocked|' "$case_root/state/resource-profile/monero" || fail "dirty Monero stop was not marked blocked"

grep -q '^ProtectSystem=strict$' packaging/systemd/bitcoin-starter-stack-resource-profile.service || fail "systemd service is not filesystem-hardened"
grep -q '^RestrictAddressFamilies=AF_UNIX$' packaging/systemd/bitcoin-starter-stack-resource-profile.service || fail "systemd service can use public network sockets"
grep -q '^Persistent=true$' packaging/systemd/bitcoin-starter-stack-resource-profile.timer || fail "systemd timer does not catch up after reboot"

echo "PASS: test_resource_profile.sh"
