#!/usr/bin/env bash
# ./stack CLI: usage paths and the docker-free backup/restore round-trip.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

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
# shellcheck disable=SC2012 # fixed filename, ls is the portable way to read the mode string
perms=$(ls -l .env | cut -c1-10)
[ "$perms" = "-rw-------" ] || fail "restored .env is not mode 600"

# restore without -y aborts on anything but yes
echo n | ./stack restore "$archive" >/dev/null 2>&1 && fail "restore proceeded without confirmation"

# init wizard builds config.json from piped answers (Enter = default; last = don't start)
rm -f config.json .env
# user[Enter] pass[Enter=random] dashpass=hunter2 onion=y control=y inbound=n prune=10 start=n
printf '\n\nhunter2\ny\ny\nn\n10\nn\n' | ./stack init >/dev/null
[ -f config.json ] || fail "init did not write config.json"
[ "$(jq -r '.dashboard.password' config.json)" = "hunter2" ] || fail "init: dashboard password"
[ "$(jq -r '.dashboard.onion' config.json)" = "true" ] || fail "init: dashboard onion"
[ "$(jq -r '.dashboard.control' config.json)" = "true" ] || fail "init: answering y should enable dashboard control"
[ "$(jq -r '.bitcoin.inbound_onion' config.json)" = "false" ] || fail "init: declining inbound records false (default is on)"
[ "$(jq -r 'has("sync_over_clearnet") or (.bitcoin | has("sync_over_clearnet"))' config.json)" = "false" ] || fail "init: clearnet setting should be absent"
[ "$(jq -r '.bitcoin.prune_mb' config.json)" = "10000" ] || fail "init: 10 GB should render 10000 MB"
[ "$(jq -r '.bitcoin.node_username // "unset"' config.json)" = "unset" ] || fail "init: default username should be omitted"
[ "$(jq -r '.bitcoin.node_password // "unset"' config.json)" = "unset" ] || fail "init: random password should be omitted"
# the generated config must feed configure.sh cleanly (creds auto-generated)
./configure.sh >/dev/null || fail "configure.sh rejected the wizard's config.json"
grep -q '^BITCOIN_RPC_USER=bitcoin$' .env || fail "wizard config: username default not applied"
grep -q '^DASHBOARD_PASSWORD=hunter2$' .env || fail "wizard config: dashboard password not rendered"

# Enter at the dashboard-password prompt generates a strong one (#76):
# overwrite=y user pass dashpass[Enter=generate] onion=n control=n inbound=n prune start=n
printf 'y\n\n\n\nn\nn\nn\n\nn\n' | ./stack init >/dev/null
jq -r '.dashboard.password' config.json | grep -qE '^[0-9a-f]{32}$' ||
  fail "init: empty dashboard password should generate a 32-hex one"
[ "$(jq -r '.dashboard.control // false' config.json)" = "false" ] ||
  fail "init: upgrade button must default to off"

# ensure_agent: up/apply must start the agent + install the @reboot cron entry
# when dashboard.control is on, remove both when off, and defer to systemd.
# Everything host-touching (crontab, docker, pgrep/pkill, setsid, systemctl) is
# stubbed onto PATH so the real machine is never modified.
stub=$tmp/stubs
mkdir -p "$stub"
export FAKE_CRON="$tmp/fake-crontab" FAKE_LOG="$tmp/stub-calls.log"
cat >"$stub/crontab" <<'EOS'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then [ -f "$FAKE_CRON" ] && cat "$FAKE_CRON" || exit 1; else cat >"$FAKE_CRON"; fi
EOS
cat >"$stub/docker" <<'EOS'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
if [ "${1:-}" = info ]; then
  if [ -n "${FAKE_DOCKER_INFO:-}" ]; then printf '%s\n' "$FAKE_DOCKER_INFO"; else printf '{}\n'; fi
fi
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
cat >"$stub/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$stub"/*
echo '{"dashboard": {"password": "hunter2", "control": true}}' >config.json

# control on -> cron entry installed, agent started
out=$(HOME="$tmp" PATH="$stub:$PATH" ./stack apply)
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
HOME="$tmp" PATH="$stub:$PATH" ./stack up --build >/dev/null 2>&1 && fail "up allows an implicit build"

# Image downloads fail before contacting a registry unless the daemon uses Tor.
rm -f "$FAKE_LOG"
HOME="$tmp" PATH="$stub:$PATH" ./stack pull >/dev/null 2>&1 && fail "pull accepted an unproxied daemon"
grep -q 'docker compose pull' "$FAKE_LOG" && fail "unproxied pull reached the registry command"
cat >"$stub/curl" <<'EOS'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_LOG"
printf '{"IsTor":true}\n'
EOS
chmod +x "$stub/curl"
export FAKE_DOCKER_INFO='{"HttpProxy":"socks5h://172.29.0.25:9050","HttpsProxy":"socks5h://172.29.0.25:9050","NoProxy":"","RegistryConfig":{"Mirrors":[]}}'
HOME="$tmp" PATH="$stub:$PATH" ./stack pull >/dev/null || fail "verified Tor pull failed"
grep -q 'curl .*--proxy socks5h://172.29.0.25:9050 --noproxy ' "$FAKE_LOG" || fail "Tor verification can bypass its proxy"
grep -q 'docker compose pull' "$FAKE_LOG" || fail "verified pull did not run"
for bad_info in \
  '{"HttpProxy":"socks5h://172.29.0.25:9050","HttpsProxy":"socks5h://172.29.0.25:9050","NoProxy":"*"}' \
  '{"HttpProxy":"http://proxy:3128","HttpsProxy":"http://proxy:3128"}' \
  '{"HttpProxy":"socks5h://172.29.0.25:9050","HttpsProxy":"socks5h://172.29.0.25:9050","RegistryConfig":{"Mirrors":["https://mirror.example"]}}'; do
  FAKE_DOCKER_INFO="$bad_info" HOME="$tmp" PATH="$stub:$PATH" ./stack pull >/dev/null 2>&1 && fail "pull accepted an unsafe proxy configuration"
done
unset FAKE_DOCKER_INFO

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
rm -f "$stub/git" "$stub/curl"

# control off -> cron entry removed, agent killed
echo '{"dashboard": {"password": "hunter2", "control": false}}' >config.json
out=$(HOME="$tmp" PATH="$stub:$PATH" ./stack apply)
grep -q "stack upgrade-agent" "$FAKE_CRON" && fail "ensure_agent: cron entry not removed"
grep -q "pkill" "$FAKE_LOG" || fail "ensure_agent: agent not stopped"
printf '%s' "$out" | grep -q "upgrade-agent: stopped" || fail "ensure_agent: stop not reported"

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
