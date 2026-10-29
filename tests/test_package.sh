#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

if ! command -v dpkg-deb >/dev/null; then
  echo "SKIP: test_package.sh (dpkg-deb not installed)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source_version=$(cat VERSION)
unset PACKAGE_VERSION
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
default_deb="dist/bitcoin-starter-stack_${source_version}_all.deb"
cp "$default_deb" "$tmp/default-first.deb"
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
cmp -s "$tmp/default-first.deb" "$default_deb" || fail "default package build is not reproducible"

export PACKAGE_VERSION=1.31.1-0pr125.abcdef0
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
deb="dist/bitcoin-starter-stack_${PACKAGE_VERSION}_all.deb"
cp "$deb" "$tmp/first.deb"
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
cmp -s "$tmp/first.deb" "$deb" || fail "package build is not reproducible"

dpkg-deb -c "$deb" >"$tmp/contents"
[ "$(dpkg-deb -f "$deb" Version)" = "$PACKAGE_VERSION" ] || fail "package version override was ignored"
for invalid in 1.0+candidate candidate; do
  invalid_deb="dist/bitcoin-starter-stack_${invalid}_all.deb"
  rm -f "$invalid_deb"
  PACKAGE_VERSION=$invalid SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null 2>&1 && fail "invalid package version was accepted: $invalid"
  [ ! -e "$invalid_deb" ] || fail "invalid package version produced an artifact: $invalid"
done
for required in \
  ./usr/bin/bitcoin-stack \
  ./usr/lib/bitcoin-starter-stack/stack \
  ./usr/lib/bitcoin-starter-stack/configure.sh \
  ./usr/lib/bitcoin-starter-stack/docker-compose.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.rpc.yml \
  ./usr/lib/bitcoin-starter-stack/build/dashboard/main.go \
  ./usr/lib/bitcoin-starter-stack/build/tor/torrc \
  ./usr/share/doc/bitcoin-starter-stack/README.md \
  ./usr/share/doc/bitcoin-starter-stack/docs/privacy.md; do
  grep -q " $required$" "$tmp/contents" || fail "package is missing $required"
done
if grep -Eq '/(tests|parity|experiments|images|__pycache__|\.pytest_cache)/|_test\.go$|\.test\.mjs$|package\.json$|/\.coverage$|\.pyc$|docs/releasing\.md$|\.(jpg|jpeg)$' "$tmp/contents"; then
  fail "package contains development-only files"
fi
if grep -Eq ' \./(etc|var)/' "$tmp/contents"; then
  fail "package owns mutable system configuration or state"
fi
depends=$(dpkg-deb -f "$deb" Depends)
printf '%s' "$depends" | grep -q 'docker-ce | docker.io' || fail "Docker Engine dependency alternatives are missing"
printf '%s' "$depends" | grep -q 'curl' || fail "curl dependency is missing"
printf '%s' "$depends" | grep -q 'docker-compose-plugin (>= 2.33.1) | docker-compose-v2 (>= 2.33.1) | docker-compose (>= 2.33.1)' || fail "Compose v2 dependency alternatives are missing minimum versions"

mkdir "$tmp/control"
dpkg-deb -e "$deb" "$tmp/control"
for hook in preinst postinst prerm postrm; do
  [ ! -e "$tmp/control/$hook" ] || fail "package contains lifecycle hook $hook"
done

root=$tmp/root
dpkg-deb -x "$deb" "$root"
[ "$(cat "$root/usr/lib/bitcoin-starter-stack/VERSION")" = "$PACKAGE_VERSION" ] || fail "payload VERSION does not match package metadata"
privacy=$root/usr/share/doc/bitcoin-starter-stack/docs/privacy.md
grep -q '^expected=UNPUBLISHED$' "$privacy" || fail "unreleased feed key is not fail-closed"
grep -q -- '--proxy socks5h://172.29.0.25:9050 --noproxy' "$privacy" || fail "feed key download is not pinned to the Tor proxy"
grep -q -- 'gpg --batch --show-keys --with-colons' "$privacy" || fail "feed key fingerprint is not verified"
if [ "$(id -u)" -ne 0 ]; then
  echo "PASS: test_package.sh artifact checks"
  echo "SKIP: test_package.sh lifecycle checks require root; the dedicated package CI job runs them"
  exit 0
fi
fake=$tmp/fake-bin
mkdir "$fake"
cat >"$fake/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "${1:-}" = inspect ]; then
  [ -n "${FAKE_EXISTING_CONFIG:-}" ] || exit 1
  printf '%s\n' "$FAKE_EXISTING_CONFIG"
fi
if [ "${FAKE_SOURCE_VOLUMES:-}" = 1 ] && [ "${1:-}" = compose ]; then
  case " $* " in
    *' --project-name bitcoin-starter-stack-apt '*) ;;
    *) exit 88 ;;
  esac
fi
EOF
chmod +x "$fake/docker"

home=$tmp/home
config_dir=$tmp/etc/bitcoin-starter-stack
state_dir=$tmp/var/lib/bitcoin-starter-stack
data_root=$state_dir/data
log=$tmp/docker.log
wrapper=$root/usr/bin/bitcoin-stack
runtime=$root/usr/lib/bitcoin-starter-stack
export HOME=$home BITCOIN_STACK_CONFIG_DIR=$config_dir BITCOIN_STACK_STATE_DIR=$state_dir BITCOIN_STACK_DATA_DIR=$data_root
export BITCOIN_STACK_ROOT=$runtime FAKE_DOCKER_LOG=$log PATH=$fake:$PATH

"$wrapper" help | grep -q 'Usage: bitcoin-stack' || fail "package command help is wrong"
[ ! -e "$log" ] || fail "help invoked Docker"
out=$("$wrapper" upgrade)
printf '%s' "$out" | grep -q 'sudo apt install --only-upgrade bitcoin-starter-stack' || fail "upgrade omitted APT instructions"
[ ! -e "$log" ] || fail "package upgrade invoked Docker"

wizard_out=$(printf 'packagepassword1234567890\n\n\nn\n\nn\n' | "$wrapper" init)
printf '%s' "$wizard_out" | grep -q 'Publish the dashboard' && fail "package wizard still prompts for dashboard onion publishing"
printf '%s' "$wizard_out" | grep -q 'Accept inbound Bitcoin' && fail "package wizard still prompts for inbound onion connections"
printf '%s' "$wizard_out" | grep -q 'One-click upgrades' && fail "package wizard offered unsupported dashboard upgrades"
[ "$(jq -r '.bitcoin.node_password' "$config_dir/config.json")" = packagepassword1234567890 ] || fail "package wizard did not save the shared password"
[ "$(jq -r '.dashboard.password' "$config_dir/config.json")" = packagepassword1234567890 ] || fail "package wizard did not share the dashboard password"
[ "$(jq -r '.bitcoin.prune_mb' "$config_dir/config.json")" = 10000 ] || fail "package wizard did not keep the fresh pruning default"
[ "$(jq -r '.bitcoin.data_dir // empty' "$config_dir/config.json")" = "" ] || fail "package wizard stored the default FHS data path"
[ "$(printf '%s' "$wizard_out" | grep -c 'Password: packagepassword1234567890')" = 1 ] || fail "package wizard did not print the new login exactly once"
rm -f "$config_dir/config.json"

"$wrapper" apply >/dev/null
env_file=$state_dir/.env
[ -f "$env_file" ] || fail "generated state is outside the package state directory"
grep -q "^BITCOIN_DATA_DIR=$data_root/bitcoin$" "$env_file" || fail "data path is outside the package data directory"
grep -q '^BITCOIN_PRUNE=10000$' "$env_file" || fail "fresh package install is not pruned to 10000 MB"
grep -q '^BITCOIN_RPC_EXPOSE=0$' "$env_file" || fail "fresh package install exposed RPC"
grep -q '^COMPOSE_FILE=docker-compose.yml$' "$env_file" || fail "fresh package install enabled an optional Compose override"
grep -q "^STACK_ROOT=$runtime$" "$env_file" || fail "immutable payload path was not rendered"
wallets=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$env_file" | base64 -d)
[ "$wallets" = '[]' ] || fail "fresh pruned package seeded a wallet it cannot scan"
[ -d "$data_root/bitcoin" ] || fail "data directory was not created"
[ "$(stat -c %u "$data_root/bitcoin")" = 1000 ] || fail "data directory is not owned by the container uid"
[ "$(stat -c %a "$data_root/bitcoin")" = 700 ] || fail "data directory permissions are not private"
[ ! -e "$home" ] || fail "package wrote configuration or data under HOME"
[ ! -e "$runtime/.env" ] || fail "package wrote state into /usr/lib payload"
grep -q -- "--project-directory $state_dir" "$log" || fail "Compose project directory is not package state"
grep -q -- "--project-name bitcoin-starter-stack-apt" "$log" || fail "package Compose project is not isolated from source installs"
grep -q -- "--env-file $env_file" "$log" || fail "Compose did not use package state env"
grep -q -- "-f $runtime/docker-compose.yml up -d" "$log" || fail "Compose did not use immutable payload"
grep -q -- "-f $runtime/docker-compose.rpc.yml" "$log" && fail "default package startup loaded the RPC override"

rm -f "$env_file"
printf '%s\n' '{"bitcoin":{"rpc_expose":true,"rpc_bind_ip":"192.168.1.117","rpc_port":18332},"wallets":[{"name":"Configured","key":"34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo"}]}' >"$config_dir/config.json"
: >"$log"
"$wrapper" apply >/dev/null
grep -q '^BITCOIN_PRUNE=10000$' "$env_file" || fail "unrelated fresh config disabled the package pruning default"
grep -q '^BITCOIN_RPC_EXPOSE=1$' "$env_file" || fail "package did not enable requested LAN RPC exposure"
grep -q '^COMPOSE_FILE=docker-compose.yml:docker-compose.rpc.yml$' "$env_file" || fail "package did not select the RPC Compose override"
wallets=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$env_file" | base64 -d)
[ "$(printf '%s' "$wallets" | jq -r '.[0].name')" = Configured ] || fail "explicit wallet configuration was replaced on a pruned package"
grep -q -- "-f $runtime/docker-compose.yml -f $runtime/docker-compose.rpc.yml up -d" "$log" || fail "package did not load the RPC Compose override from immutable payload"

: >"$log"
FAKE_SOURCE_VOLUMES=1 "$wrapper" apply >/dev/null || fail "stale source volumes blocked the isolated package project"
grep -q -- "--project-name bitcoin-starter-stack-apt" "$log" || fail "package could reuse source-managed named volumes"

printf '%s\n' '{"bitcoin":{"prune_mb":0,"rpc_expose":true,"rpc_bind_ip":"192.168.1.117","rpc_port":18332}}' >"$config_dir/config.json"
: >"$log"
"$wrapper" apply >/dev/null
grep -q '^BITCOIN_PRUNE=0$' "$env_file" || fail "explicit full-node configuration was replaced by the package default"
grep -q '^BITCOIN_RPC_EXPOSE=1$' "$env_file" || fail "package did not enable requested LAN RPC exposure"
grep -q '^COMPOSE_FILE=docker-compose.yml:docker-compose.rpc.yml$' "$env_file" || fail "package did not select the RPC Compose override"
grep -q '"prune_mb":0' "$config_dir/config.json" || fail "package rewrote explicit configuration"
grep -q -- "-f $runtime/docker-compose.yml -f $runtime/docker-compose.rpc.yml up -d" "$log" || fail "package did not load the RPC Compose override from immutable payload"
rm -f "$config_dir/config.json"
"$wrapper" apply >/dev/null
grep -q '^BITCOIN_PRUNE=0$' "$env_file" || fail "existing full-node state was converted to pruning"

: >"$log"
FAKE_EXISTING_CONFIG=/source/bitcoin-starter-stack/docker-compose.yml "$wrapper" up >"$tmp/existing.out" 2>&1 && fail "package startup replaced a source-managed container"
grep -q 'belongs to another installation' "$tmp/existing.out" || fail "existing deployment refusal is unclear"
grep -q 'compose .* up ' "$log" && fail "existing deployment refusal reached Compose up"

printf '%s\n' '{"dashboard":{"control":true}}' >"$config_dir/config.json"
rm -f "$log"
"$wrapper" apply >"$tmp/control.out" 2>&1 && fail "APT mode accepted dashboard.control"
grep -q 'dashboard.control is unavailable' "$tmp/control.out" || fail "dashboard.control rejection is unclear"
[ ! -e "$log" ] || fail "rejected config invoked Docker"

bad=$tmp/not-a-directory
: >"$bad"
BITCOIN_STACK_CONFIG_DIR=$bad "$wrapper" help >"$tmp/bad.out" 2>&1 && fail "non-directory config path was accepted"
grep -q 'is not a directory' "$tmp/bad.out" || fail "bad package path error is unclear"

rm -rf "$root"
[ -f "$env_file" ] || fail "package removal simulation deleted user state"
echo "PASS: test_package.sh"
