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
# user[Enter] pass[Enter=random] dashpass=hunter2 onion=y inbound=n clearnet=n prune=10 start=n
printf '\n\nhunter2\ny\nn\nn\n10\nn\n' | ./stack init >/dev/null
[ -f config.json ] || fail "init did not write config.json"
[ "$(jq -r '.dashboard.password' config.json)" = "hunter2" ] || fail "init: dashboard password"
[ "$(jq -r '.dashboard.onion' config.json)" = "true" ] || fail "init: dashboard onion"
[ "$(jq -r '.bitcoin.inbound_onion' config.json)" = "false" ] || fail "init: declining inbound records false (default is on)"
[ "$(jq -r '.bitcoin.sync_over_clearnet // false' config.json)" = "false" ] || fail "init: clearnet should be off"
[ "$(jq -r '.bitcoin.prune_mb' config.json)" = "10000" ] || fail "init: 10 GB should render 10000 MB"
[ "$(jq -r '.bitcoin.node_username // "unset"' config.json)" = "unset" ] || fail "init: default username should be omitted"
[ "$(jq -r '.bitcoin.node_password // "unset"' config.json)" = "unset" ] || fail "init: random password should be omitted"
# the generated config must feed configure.sh cleanly (creds auto-generated)
./configure.sh >/dev/null || fail "configure.sh rejected the wizard's config.json"
grep -q '^BITCOIN_RPC_USER=bitcoin$' .env || fail "wizard config: username default not applied"
grep -q '^DASHBOARD_PASSWORD=hunter2$' .env || fail "wizard config: dashboard password not rendered"

# Enter at the dashboard-password prompt generates a strong one (#76):
# overwrite=y user pass dashpass[Enter=generate] onion=n inbound=n clearnet=n prune start=n
printf 'y\n\n\n\nn\nn\nn\n\nn\n' | ./stack init >/dev/null
jq -r '.dashboard.password' config.json | grep -qE '^[0-9a-f]{32}$' ||
  fail "init: empty dashboard password should generate a 32-hex one"

echo "PASS: test_cli.sh"
