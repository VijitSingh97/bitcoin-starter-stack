#!/usr/bin/env bash
# ./stack CLI: usage paths and the docker-free backup/restore round-trip.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

[ -x scripts/node-control ] || fail "source node-control helper is not executable"
grep -Fq 'scripts/node-control" || echo "upgrade-agent: node control check failed' stack ||
  fail "upgrade-agent does not run node-control"
for private_runtime_path in credential-control/transaction.after port-control/request.json node-control/transaction.after; do
  git check-ignore -q "$private_runtime_path" || fail "private runtime path is not ignored: $private_runtime_path"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp stack configure.sh config.example.json "$tmp/"
printf '1.2.3\n' >"$tmp/VERSION"
cd "$tmp"

# help works, unknown command fails loudly
./stack help | grep -q "Usage:" || fail "help does not print usage"
./stack definitely-not-a-command >/dev/null 2>&1 && fail "unknown command exited 0"

# backup captures config + .env; restore round-trips them
cat >config.json <<'EOF'
{"bitcoin": {"node_username": "cliuser", "node_password": "clipass1"}}
EOF
./configure.sh >/dev/null
./stack backup | grep -q "Wrote backups/" || fail "backup did not report an archive"
archive=$(ls backups/stack-backup-*.tar.gz)
tar tzf "$archive" | grep -q "config.json" || fail "backup missing config.json"
tar tzf "$archive" | grep -q ".env" || fail "backup missing .env"

echo '{"bitcoin": {"node_username": "changed", "node_password": "changed1"}}' >config.json
rm .env
./stack restore -y "$archive" >/dev/null
grep -q "cliuser" config.json || fail "restore did not bring back config.json"
grep -q "^BITCOIN_RPC_USER=cliuser$" .env || fail "restore did not bring back .env"
[ -f .approved-config.json ] || fail "explicit restore did not approve the restored config"
cmp -s .env .approved.env || fail "explicit restore did not approve the restored environment"
# shellcheck disable=SC2012 # fixed filename, ls is the portable way to read the mode string
perms=$(ls -l .env | cut -c1-10)
[ "$perms" = "-rw-------" ] || fail "restored .env is not mode 600"
# shellcheck disable=SC2012 # fixed filename, ls is the portable way to read the mode string
perms=$(ls -l config.json | cut -c1-10)
[ "$perms" = "-rw-------" ] || fail "restored config.json is not mode 600"

# restore without -y aborts on anything but yes
echo n | ./stack restore "$archive" >/dev/null 2>&1 && fail "restore proceeded without confirmation"


# ensure_agent: up/apply must start the host-control agent + install the @reboot
# cron entry when a dashboard password is set, and defer to systemd.
# Everything host-touching (crontab, docker, pgrep/pkill, setsid, systemctl) is
# stubbed onto PATH so the real machine is never modified.
stub=$tmp/stubs
mkdir -p "$stub"
export FAKE_CRON="$tmp/fake-crontab" FAKE_LOG="$tmp/stub-calls.log" FAKE_IMAGES_READY="$tmp/images-ready" REAL_JQ_BIN
REAL_JQ_BIN=$(command -v jq)
cat >"$stub/crontab" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then [ -f "$FAKE_CRON" ] && cat "$FAKE_CRON" || exit 1; else cat >"$FAKE_CRON"; fi
EOS
cat >"$stub/docker" <<'EOS'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
case " $* " in
  *' info '*) [ "${FAKE_DOCKER_INFO_FAIL:-0}" != 1 ]; exit ;;
  *' exec dashboard cat /state/dashboard_auth.json '*) [ -f "${FAKE_DASH_AUTH_FILE:-}" ] && cat "$FAKE_DASH_AUTH_FILE"; exit ;;
  *' compose config --images '*) printf 'example.invalid/stack:test\n' ;;
  *' image inspect '*) [ "${FAKE_IMAGES_MISSING:-0}" != 1 ] || [ -f "$FAKE_IMAGES_READY" ]; exit ;;
  *' compose pull '*) [ "${FAKE_PULL_FAIL:-0}" != 1 ] || exit 1; touch "$FAKE_IMAGES_READY"; exit ;;
  *' compose up '*) [ "${FAKE_UP_FAIL:-0}" != 1 ]; exit ;;
  *'com.docker.compose.project.config_files'*) exit 1 ;;
  *' inspect --format {{.State.Running}} dashboard '*) printf 'true\n' ;;
esac
exit 0
EOS
cat >"$stub/pgrep" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
cat >"$stub/pkill" <<'EOS'
#!/usr/bin/env bash
echo "pkill $*" >>"$FAKE_LOG"; exit 0
EOS
cat >"$stub/setsid" <<'EOS'
#!/usr/bin/env bash
echo "setsid $*" >>"$FAKE_LOG"; exit 0
EOS
cat >"$stub/nohup" <<'EOS'
#!/usr/bin/env bash
echo "nohup $*" >>"$FAKE_LOG"
exit 0
EOS
cat >"$stub/brew" <<'EOS'
#!/usr/bin/env bash
echo "brew $*" >>"$FAKE_LOG"
[ "${FAKE_BREW_FAIL:-0}" != 1 ]
EOS
cat >"$stub/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
cat >"$stub/uname" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-Linux}"
EOS
cat >"$stub/flock" <<'EOS'
#!/usr/bin/env bash
echo "flock $*" >>"$FAKE_LOG"
EOS
cat >"$stub/jq" <<'EOS'
#!/usr/bin/env bash
if [ "${FAKE_APPROVE_FAIL:-0}" = 1 ] && [ "${1:-}" = -S ] && [ "${2:-}" = . ] && [ "$#" = 3 ]; then
  exit 73
fi
exec "$REAL_JQ_BIN" "$@"
EOS
chmod +x "$stub"/*

wizard="$tmp/wizard"
mkdir "$wizard"
cp stack configure.sh "$wizard/"
printf '1.2.3\n' >"$wizard/VERSION"
rm -f "$FAKE_LOG"
rm -f "$FAKE_IMAGES_READY"
(cd "$wizard" &&
  BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 FAKE_IMAGES_MISSING=1 HOME="$tmp" PATH="$stub:$PATH" ./stack init >"$tmp/wizard-init.log" 2>&1) || {
  cat "$tmp/wizard-init.log"
  fail "init failed with mocked Linux host controls"
}
grep -q 'docker compose pull' "$FAKE_LOG" || fail "init did not pull missing images"
grep -q 'docker compose up -d --pull never --no-build' "$FAKE_LOG" || fail "init start allows implicit downloads or builds"
[ "$(jq -r '.bitcoin.enabled' "$wizard/config.json")" = true ] || fail "init did not default to Bitcoin"
[ "$(jq -r '.dashboard.password' "$wizard/config.json")" = "" ] || fail "init did not default to a passwordless dashboard"
[ "$(jq -r '.dashboard.bind_ip' "$wizard/config.json")" = auto ] || fail "init did not keep the dashboard bind dynamic"
[ "$(jq -r '.dashboard.launch_at_boot' "$wizard/config.json")" = false ] || fail "init enabled launch at boot"
grep -q '^DASHBOARD_BIND_IP=192.168.1.116$' "$wizard/.env" || fail "init did not use the detected LAN address"
grep -q '^BITCOIN_PRUNE=10000$' "$wizard/.env" || fail "init did not default to a pruned node"
grep -q '^COMPOSE_PROFILES=bitcoin$' "$wizard/.env" || fail "init enabled extra nodes"
grep -q '^BITCOIN_RPC_EXPOSE=0$' "$wizard/.env" || fail "init exposed Bitcoin RPC"
[ -f "$wizard/.approved-config.json" ] || fail "init did not approve its config"
grep -q 'Dashboard password — default off; any password saved in Settings still applies' "$tmp/wizard-init.log" || fail "init did not report its dashboard password default"
grep -q 'Bitcoin RPC — username: admin  password:' "$tmp/wizard-init.log" || fail "init did not print the selected node credentials"

wizard_loaded="$tmp/wizard-loaded"
mkdir "$wizard_loaded"
cp stack configure.sh "$wizard_loaded/"
printf '1.2.3\n' >"$wizard_loaded/VERSION"
rm -f "$FAKE_LOG"
cat >"$wizard_loaded/config.json" <<'EOF'
{"bitcoin":{"enabled":false},"monero":{"enabled":true,"data_dir":"./custom-monero","node_password":"moneropassword1234567890123456"},"dashboard":{"password":"customdashboardpassword","bind_ip":"192.168.1.118"}}
EOF
(cd "$wizard_loaded" && HOME="$tmp" PATH="$stub:$PATH" ./stack init >"$tmp/wizard-loaded.log")
grep -q 'docker compose pull' "$FAKE_LOG" && fail "init pulled images that were already local"
grep -q 'docker compose up -d --pull never --no-build' "$FAKE_LOG" || fail "init did not start local images"
[ "$(jq -r '.monero.data_dir' "$wizard_loaded/config.json")" = ./custom-monero ] || fail "init replaced a preseeded data path"
[ "$(jq -r '.monero.node_password' "$wizard_loaded/config.json")" = moneropassword1234567890123456 ] || fail "init replaced a preseeded credential"
grep -q '^COMPOSE_PROFILES=monero$' "$wizard_loaded/.env" || fail "init replaced a preseeded node selection"
grep -q '^DASHBOARD_PASSWORD=customdashboardpassword$' "$wizard_loaded/.env" || fail "init replaced a preseeded dashboard password"
grep -q 'Dashboard — username: admin  password: customdashboardpassword' "$tmp/wizard-loaded.log" || fail "init did not print the preset dashboard credential"
grep -q 'Monero RPC — username: admin  password: moneropassword1234567890123456' "$tmp/wizard-loaded.log" || fail "init did not print the selected fixture node credential"
loaded_config=$(shasum -a 256 "$wizard_loaded/config.json" | cut -d' ' -f1)
(cd "$wizard_loaded" && HOME="$tmp" PATH="$stub:$PATH" ./stack init >/dev/null)
[ "$(shasum -a 256 "$wizard_loaded/config.json" | cut -d' ' -f1)" = "$loaded_config" ] || fail "repeated init changed a preseeded config"

wizard_failed="$tmp/wizard-failed"
mkdir "$wizard_failed"
cp stack configure.sh "$wizard_failed/"
printf '1.2.3\n' >"$wizard_failed/VERSION"
rm -f "$FAKE_LOG"
rm -f "$FAKE_IMAGES_READY"
(cd "$wizard_failed" &&
  BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 FAKE_IMAGES_MISSING=1 FAKE_PULL_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack init >/dev/null 2>&1) &&
  fail "init ignored a missing-image pull failure"
grep -q 'docker compose pull' "$FAKE_LOG" || fail "init failure did not attempt a pull"
grep -q 'docker compose up -d' "$FAKE_LOG" && fail "init started after a failed pull"

wizard_no_docker="$tmp/wizard-no-docker"
mkdir "$wizard_no_docker"
cp stack configure.sh "$wizard_no_docker/"
printf '1.2.3\n' >"$wizard_no_docker/VERSION"
(cd "$wizard_no_docker" &&
  BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 FAKE_DOCKER_INFO_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack init >"$tmp/no-docker.log" 2>&1) &&
  fail "init succeeded while Docker was unavailable"
[ -f "$wizard_no_docker/config.json" ] || fail "init discarded its config when Docker was unavailable"
[ ! -f "$wizard_no_docker/.approved-config.json" ] || fail "init approved a config that was not started"
grep -q 'Configuration was saved, but Docker is not ready' "$tmp/no-docker.log" || fail "init did not explain how to recover when Docker was unavailable"

pending="$tmp/pending-config"
mkdir "$pending"
cp stack configure.sh "$pending/"
printf '1.2.3\n' >"$pending/VERSION"
(cd "$pending" && BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 HOME="$tmp" PATH="$stub:$PATH" ./stack init >/dev/null)
(cd "$pending" && BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.117 HOME="$tmp" PATH="$stub:$PATH" ./stack up >/dev/null)
grep -q '^DASHBOARD_BIND_IP=192.168.1.117$' "$pending/.env" || fail "start did not refresh an automatic LAN bind"
jq '.dashboard.port=8088' "$pending/config.json" >"$pending/config.next"
mv "$pending/config.next" "$pending/config.json"
(cd "$pending" && BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.117 ./configure.sh >/dev/null)
grep -q '^DASHBOARD_PORT=8088$' "$pending/.env" || fail "pending config test did not render its changed environment"
out=$(cd "$pending" && HOME="$tmp" PATH="$stub:$PATH" ./stack up)
printf '%s' "$out" | grep -q 'Config change detected' || fail "noninteractive start did not report a pending config"
grep -q '^DASHBOARD_PORT=80$' "$pending/.env" || fail "noninteractive start silently applied a pending config"
[ "$(jq -r '.dashboard.port // 80' "$pending/.approved-config.json")" = 80 ] || fail "noninteractive start approved a pending config"
out=$(cd "$pending" && printf 'n\n' | BITCOIN_STACK_INTERACTIVE=1 HOME="$tmp" PATH="$stub:$PATH" ./stack restart)
printf '%s' "$out" | grep -q 'Run new config?' || fail "manual restart did not ask before applying a pending config"
grep -q '^DASHBOARD_PORT=80$' "$pending/.env" || fail "declined config was applied"
(cd "$pending" && printf 'y\n' | BITCOIN_STACK_INTERACTIVE=1 HOME="$tmp" PATH="$stub:$PATH" ./stack restart >/dev/null)
grep -q '^DASHBOARD_PORT=8088$' "$pending/.env" || fail "accepted config was not applied"
[ "$(jq -r '.dashboard.port' "$pending/.approved-config.json")" = 8088 ] || fail "accepted config was not approved"
jq '.dashboard.port=8090' "$pending/config.json" >"$pending/config.next"
mv "$pending/config.next" "$pending/config.json"
(cd "$pending" && FAKE_UP_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null 2>&1) && fail "failed apply returned success"
grep -q '^DASHBOARD_PORT=8088$' "$pending/.env" || fail "failed apply did not restore the previous runtime environment"
[ "$(jq -r '.dashboard.port' "$pending/.approved-config.json")" = 8088 ] || fail "failed apply replaced the approved config"
cp "$pending/.approved.env" "$pending/approved-env.before"
: >"$FAKE_LOG"
(cd "$pending" && FAKE_APPROVE_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null 2>&1) && fail "apply succeeded after approval failed"
grep -q '^DASHBOARD_PORT=8088$' "$pending/.env" || fail "approval failure did not restore the previous runtime environment"
[ "$(jq -r '.dashboard.port' "$pending/.approved-config.json")" = 8088 ] || fail "approval failure replaced the approved config"
cmp -s "$pending/.approved.env" "$pending/approved-env.before" || fail "approval failure replaced the approved environment"
[ "$(grep -c 'docker compose up -d --pull never --no-build' "$FAKE_LOG")" -ge 2 ] || fail "approval failure did not reconcile the previous runtime"
cp "$pending/config.json" "$pending/config.before-invalid"
printf '{\n' >"$pending/config.json"
: >"$FAKE_LOG"
(cd "$pending" && HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null 2>&1) && fail "invalid config apply returned success"
grep -q '^docker ' "$FAKE_LOG" && fail "invalid config apply touched the runtime"
grep -q '^DASHBOARD_PORT=8088$' "$pending/.env" || fail "invalid config apply did not restore the previous environment"
[ "$(jq -r '.dashboard.port' "$pending/.approved-config.json")" = 8088 ] || fail "invalid config apply replaced the approved config"
cmp -s "$pending/.approved.env" "$pending/approved-env.before" || fail "invalid config apply replaced the approved environment"
mv "$pending/config.before-invalid" "$pending/config.json"

fresh_invalid="$tmp/fresh-invalid-config"
mkdir "$fresh_invalid"
cp stack configure.sh "$fresh_invalid/"
printf '1.2.3\n' >"$fresh_invalid/VERSION"
printf '{\n' >"$fresh_invalid/config.json"
: >"$FAKE_LOG"
(cd "$fresh_invalid" && HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null 2>&1) && fail "fresh invalid config apply returned success"
grep -q '^docker ' "$FAKE_LOG" && fail "fresh invalid config apply touched the runtime"
[ ! -f "$fresh_invalid/.env" ] || fail "fresh invalid config apply retained an environment"
[ ! -f "$fresh_invalid/.approved-config.json" ] || fail "fresh invalid config apply created an approved config"
[ ! -f "$fresh_invalid/.approved.env" ] || fail "fresh invalid config apply created an approved environment"

wizard_approval_failed="$tmp/wizard-approval-failed"
mkdir "$wizard_approval_failed"
cp stack configure.sh "$wizard_approval_failed/"
printf '1.2.3\n' >"$wizard_approval_failed/VERSION"
: >"$FAKE_LOG"
(cd "$wizard_approval_failed" && BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 FAKE_APPROVE_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack init >/dev/null 2>&1) &&
  fail "init succeeded after approval failed"
grep -q 'docker compose down' "$FAKE_LOG" || fail "fresh init approval failure did not stop the unapproved runtime"
[ ! -f "$wizard_approval_failed/.env" ] || fail "fresh init approval failure retained an unapproved environment"
[ ! -f "$wizard_approval_failed/.approved-config.json" ] || fail "fresh init approval failure retained an approved config"
[ ! -f "$wizard_approval_failed/.approved.env" ] || fail "fresh init approval failure retained an approved environment"

migration="$tmp/migration-config"
mkdir "$migration"
cp stack configure.sh "$migration/"
printf '1.2.3\n' >"$migration/VERSION"
echo '{"dashboard":{"port":80}}' >"$migration/config.json"
(cd "$migration" && BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 ./configure.sh >/dev/null)
echo '{"dashboard":{"port":8088}}' >"$migration/config.json"
out=$(cd "$migration" && HOME="$tmp" PATH="$stub:$PATH" ./stack up)
printf '%s' "$out" | grep -q 'Config change detected' || fail "legacy runtime adoption did not report the unapproved config"
grep -q '^DASHBOARD_PORT=80$' "$migration/.env" || fail "legacy runtime adoption silently applied config"
jq -e 'type == "null"' "$migration/.approved-config.json" >/dev/null || fail "legacy runtime adoption claimed an unknown config was approved"

approved_empty="$tmp/approved-empty-config"
mkdir "$approved_empty"
cp stack configure.sh "$approved_empty/"
printf '1.2.3\n' >"$approved_empty/VERSION"
printf '{}\n' >"$approved_empty/.approved-config.json"
printf 'DASHBOARD_PORT=8099\nSTACK_RESTART_POLICY=on-failure:5\nCOMPOSE_PROFILES=monero\nBITCOIN_ENABLED=0\nMONERO_ENABLED=1\nMONERO_RPC_USER=fixture-admin\nMONERO_RPC_PASSWORD=fixture-password\n' >"$approved_empty/.approved.env"
printf 'DASHBOARD_PORT=9000\n' >"$approved_empty/.env"
(cd "$approved_empty" && HOME="$tmp" PATH="$stub:$PATH" ./stack up >/dev/null)
grep -q '^DASHBOARD_PORT=8099$' "$approved_empty/.env" || fail "missing empty config did not restore the approved runtime"
grep -q '^COMPOSE_PROFILES=monero$' "$approved_empty/.env" || fail "missing empty config replaced the approved node selection"
grep -q '^MONERO_RPC_PASSWORD=fixture-password$' "$approved_empty/.env" || fail "missing empty config replaced the approved credential"

echo '{"dashboard": {"password": "hunter2", "control": true}}' >config.json

# control on -> cron entry installed, agent started
: >"$FAKE_LOG"
out=$(HOME="$tmp" PATH="$stub:$PATH" ./stack apply)
awk '/^flock 8$/ { lock=NR } /docker compose up -d --pull never --no-build/ { up=NR } /^flock -u 8$/ { unlock=NR } END { exit !(lock && lock < up && up < unlock) }' "$FAKE_LOG" ||
  fail "apply did not hold the config lock through Compose"
grep -q 'docker exec -i -u 1000 dashboard sh -c .*node-runtime.json' "$FAKE_LOG" ||
  fail "apply did not synchronize dashboard node runtime state"
grep -q "stack upgrade-agent" "$FAKE_CRON" || fail "ensure_agent: no @reboot cron entry installed"
grep -q "^@reboot" "$FAKE_CRON" || fail "ensure_agent: cron entry is not @reboot"
# the agent start is backgrounded — give the stub a moment to log the call
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'setsid ./stack upgrade-agent' "$FAKE_LOG" 2>/dev/null && break
  sleep 0.3
done
grep -q "setsid ./stack upgrade-agent" "$FAKE_LOG" || fail "ensure_agent: agent not started"
printf '%s' "$out" | grep -q "upgrade-agent: started" || fail "ensure_agent: start not reported"

# idempotent: a second apply must not duplicate the cron entry
HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null
[ "$(grep -c "stack upgrade-agent" "$FAKE_CRON")" = "1" ] || fail "ensure_agent: cron entry duplicated"
grep -q 'docker compose up -d --pull never --no-build' "$FAKE_LOG" || fail "apply allows implicit image downloads or builds"
: >"$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack apply-port-settings >/dev/null
grep -q 'docker compose up -d --pull never --no-build --no-deps tor dashboard' "$FAKE_LOG" ||
  fail "port settings apply was not limited to Tor and dashboard"
: >"$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack up >/dev/null
awk '/^flock 8$/ { lock=NR } /docker compose up -d --pull never --no-build/ { up=NR } /^flock -u 8$/ { unlock=NR } END { exit !(lock && lock < up && up < unlock) }' "$FAKE_LOG" ||
  fail "up did not hold the config lock through Compose"
: >"$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack up tari-wallet >/dev/null
grep -q 'docker compose up -d --pull never --no-build tari-wallet' "$FAKE_LOG" || fail "up rejected the Tari wallet service"
HOME="$tmp" PATH="$stub:$PATH" ./stack up --build >/dev/null 2>&1 && fail "up allows an implicit build"

# Explicit pulls use the host Docker configuration and report pull failures.
rm -f "$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack pull >/dev/null || fail "host Docker pull failed"
grep -q 'docker compose pull' "$FAKE_LOG" || fail "pull did not reach Compose"
grep -q 'docker info' "$FAKE_LOG" && fail "pull inspected or changed host Docker proxy settings"
FAKE_PULL_FAIL=1 HOME="$tmp" PATH="$stub:$PATH" ./stack pull >/dev/null 2>&1 && fail "pull failure was ignored"

cat >"$stub/git" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  'rev-parse --is-inside-work-tree') exit 0 ;;
  'remote get-url origin') printf '%s\n' "$FAKE_ORIGIN" ;;
  'tag --list --sort=-v:refname') printf 'v1.2.3\n' ;;
  *) printf 'git %s no_proxy=%s NO_PROXY=%s\n' "$*" "${no_proxy-unset}" "${NO_PROXY-unset}" >>"$FAKE_LOG" ;;
esac
EOS
chmod +x "$stub/git"
rm -f "$FAKE_LOG"
FAKE_ORIGIN=https://github.com/example/stack.git NO_PROXY='*' no_proxy='*' PATH="$stub:$PATH" ./stack upgrade >/dev/null || fail "HTTPS upgrade check failed"
grep -q 'http.proxy=socks5h://172.29.0.25:9050' "$FAKE_LOG" || fail "Git fetch has no Tor proxy"
grep -q 'protocol.allow=never -c protocol.https.allow=always fetch' "$FAKE_LOG" || fail "Git fetch can switch protocols"
grep -q 'no_proxy= NO_PROXY=$' "$FAKE_LOG" || fail "Git inherited a proxy bypass"
rm -f "$FAKE_LOG"
FAKE_ORIGIN=git@github.com:example/stack.git PATH="$stub:$PATH" ./stack upgrade >/dev/null 2>&1 && fail "SSH origin accepted"
[ ! -f "$FAKE_LOG" ] || fail "SSH upgrade attempted a network fetch"
rm -f "$stub/git"

# Upgrade control can be off while close-only LAN port controls keep the agent.
echo '{"dashboard": {"password": "hunter2", "control": false}}' >config.json
HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null
grep -q "stack upgrade-agent" "$FAKE_CRON" || fail "ensure_agent: control-off dashboard lost LAN port controls"
grep -q "pkill" "$FAKE_LOG" && fail "ensure_agent: control-off dashboard stopped the host-control agent"

# Passwordless LAN dashboards retain host controls through capability authentication.
echo '{"dashboard": {"password": "", "control": false}}' >config.json
: >"$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null
grep -q "stack upgrade-agent" "$FAKE_CRON" || fail "ensure_agent: passwordless dashboard lost host controls"
grep -q "pkill" "$FAKE_LOG" && fail "ensure_agent: passwordless dashboard stopped host controls"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^setsid ' "$FAKE_LOG" 2>/dev/null && break
  sleep 0.1
done

# Source installs on macOS must not install a Linux cron/setsid agent.
rm -f "$FAKE_CRON" "$FAKE_LOG"
echo '{"dashboard": {"password": "hunter2", "control": true}}' >config.json
out=$(FAKE_UNAME=Darwin HOME="$tmp" PATH="$stub:$PATH" ./stack apply)
[ ! -f "$FAKE_CRON" ] || fail "ensure_agent: macOS source install wrote a cron entry"
grep -q '^setsid ' "$FAKE_LOG" 2>/dev/null && fail "ensure_agent: macOS source install launched setsid"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'nohup env .*stack host-service' "$FAKE_LOG" 2>/dev/null && break
  sleep 0.1
done
grep -q 'nohup env .*stack host-service' "$FAKE_LOG" || fail "ensure_agent: macOS source install did not start host-service"
printf '%s' "$out" | grep -q 'host-service: started for this login session' || fail "ensure_agent: macOS source host-service start was not reported"

# Homebrew installs start the persistent supervisor without invoking a real service manager.
: >"$FAKE_LOG"
echo '{"dashboard": {"password": "hunter2", "control": false}}' >config.json
BITCOIN_STACK_PACKAGE_MANAGED=brew FAKE_UNAME=Darwin HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null
grep -q '^brew services start bitcoin-starter-stack$' "$FAKE_LOG" || fail "ensure_agent: Homebrew supervisor was not started"

# systemd unit enabled -> stack stays out of the way entirely
cat >"$stub/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$stub/systemctl"
rm -f "$FAKE_LOG"
echo '{"dashboard": {"password": "hunter2", "control": true}}' >config.json
HOME="$tmp" PATH="$stub:$PATH" ./stack apply >/dev/null
sleep 0.5
grep -qE '^(pkill|setsid) ' "$FAKE_LOG" && fail "ensure_agent: touched the host despite an enabled systemd unit"
grep -q "stack upgrade-agent" "$FAKE_CRON" 2>/dev/null && fail "ensure_agent: installed cron despite systemd"
rm -f config.json .env "$FAKE_CRON" "$FAKE_LOG"

# ./stack upgrade: the decision paths that don't touch docker (the real
# checkout+apply is covered by tests/test_upgrade.sh).
# (a) not a git checkout -> points at the release tarball (it exits 1, so capture
# the output rather than piping under pipefail)
out=$(./stack upgrade 2>&1 || true)
printf '%s' "$out" | grep -q "Not a git checkout" || fail "upgrade: non-git should point at the tarball"
# (b) HEAD already at the latest tag -> nothing to do
gtmp=$(mktemp -d)
cp stack configure.sh "$gtmp/"
printf '9.9.9\n' >"$gtmp/VERSION"
(
  cd "$gtmp"
  git init -q && git config user.email t@t && git config user.name t
  git add -A && git commit -qm v && git tag v9.9.9
  git remote add origin "$gtmp"
  ./stack upgrade 2>&1 | grep -q "Already on the latest release (v9.9.9)" || {
    echo "FAIL: upgrade should no-op when HEAD is the latest tag"
    exit 1
  }
  # (c) installed newer than the newest tag -> refuse to downgrade
  git tag -d v9.9.9 >/dev/null && git tag v0.0.1
  ./stack upgrade 2>&1 | grep -q "newer than the latest release" || {
    echo "FAIL: upgrade should refuse to downgrade"
    exit 1
  }
) || exit 1
rm -rf "$gtmp"

echo "PASS: test_cli.sh"
