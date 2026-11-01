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
  ./usr/lib/bitcoin-starter-stack/docker-compose.tari-wallet.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.rpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.monero-rpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.monero-zmq.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.tari-grpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.litecoin-rpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.dogecoin-rpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.bitcoincash-rpc.yml \
  ./usr/lib/bitcoin-starter-stack/docker-compose.zcash-rpc.yml \
  ./usr/lib/bitcoin-starter-stack/build/dashboard/main.go \
  ./usr/lib/bitcoin-starter-stack/build/monero/Dockerfile \
  ./usr/lib/bitcoin-starter-stack/build/monero/wallet-entrypoint.sh \
  ./usr/lib/bitcoin-starter-stack/build/monero/wallet-healthcheck.sh \
  ./usr/lib/bitcoin-starter-stack/build/tari/config.toml \
  ./usr/lib/bitcoin-starter-stack/build/tari-wallet/Dockerfile \
  ./usr/lib/bitcoin-starter-stack/build/tari-wallet/launcher.go \
  ./usr/lib/bitcoin-starter-stack/build/tari-wallet/config.toml \
  ./usr/lib/bitcoin-starter-stack/build/litecoin/Dockerfile \
  ./usr/lib/bitcoin-starter-stack/build/dogecoin/Dockerfile \
  ./usr/lib/bitcoin-starter-stack/build/bitcoincash/Dockerfile \
  ./usr/lib/bitcoin-starter-stack/build/bitcoincash/entrypoint.sh \
  ./usr/lib/bitcoin-starter-stack/build/bitcoincash/healthcheck.sh \
  ./usr/lib/bitcoin-starter-stack/build/zcash/zakurad.toml \
  ./usr/lib/bitcoin-starter-stack/build/zcash/healthcheck.sh \
  ./usr/lib/bitcoin-starter-stack/build/tor/torrc \
  ./usr/lib/bitcoin-starter-stack/node-resource-profile \
  ./usr/lib/bitcoin-starter-stack/node-port-control \
  ./usr/lib/bitcoin-starter-stack/node-control \
  ./usr/lib/systemd/system/bitcoin-starter-stack-resource-profile.service \
  ./usr/lib/systemd/system/bitcoin-starter-stack-resource-profile.timer \
  ./usr/lib/systemd/system/bitcoin-starter-stack-port-control.service \
  ./usr/lib/systemd/system/bitcoin-starter-stack-port-control.timer \
  ./usr/lib/systemd/system/bitcoin-starter-stack-node-control.service \
  ./usr/lib/systemd/system/bitcoin-starter-stack-node-control.timer \
  ./usr/share/doc/bitcoin-starter-stack/README.md \
  ./usr/share/doc/bitcoin-starter-stack/docs/nodes.md \
  ./usr/share/doc/bitcoin-starter-stack/docs/privacy.md; do
  grep -q " $required$" "$tmp/contents" || fail "package is missing $required"
done
if grep -Eq '/(tests|parity|experiments|images|__pycache__|\.pytest_cache)/|_test\.go$|\.test\.mjs$|\.proto$|package\.json$|/\.coverage$|\.pyc$|docs/releasing\.md$|\.(jpg|jpeg)$' "$tmp/contents"; then
  fail "package contains development-only files"
fi
if grep -Eq ' \./(etc|var)/' "$tmp/contents"; then
  fail "package owns mutable system configuration or state"
fi
depends=$(dpkg-deb -f "$deb" Depends)
printf '%s' "$depends" | grep -q 'docker-ce | docker.io' || fail "Docker Engine dependency alternatives are missing"
printf '%s' "$depends" | grep -q 'curl' || fail "curl dependency is missing"
printf '%s' "$depends" | grep -q 'util-linux' || fail "resource profile lock dependency is missing"
printf '%s' "$depends" | grep -q 'iproute2' || fail "port listener inspection dependency is missing"
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
grep -q "^expected='72FD656754BD7534E274360A37070C2730C0B4EA'$" "$privacy" || fail "published feed fingerprint is missing"
grep -q 'bitcoin-starter-stack.asc' "$privacy" || fail "feed key download is missing"
grep -q -- '--proxy' "$privacy" && fail "feed key download forces a host proxy"
grep -q -- 'gpg --batch --show-keys --with-colons' "$privacy" || fail "feed key fingerprint is not verified"
grep -q 'primary_keys++' "$privacy" || fail "feed key check does not reject extra primary keys"
grep -Fq "1:\$expected" "$privacy" || fail "feed key check does not bind the only primary key to the fingerprint"
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
if [ "${1:-}" = ps ] && [ "${2:-}" = -aq ]; then
  requested_service=
  for arg in "$@"; do
    case "$arg" in label=com.docker.compose.service=*) requested_service=${arg##*=} ;; esac
  done
  if [ -n "${FAKE_EXISTING_CONFIG:-}" ]; then
    existing_service=${FAKE_EXISTING_SERVICE:-tor}
    [ "$requested_service" != "$existing_service" ] || printf 'existing-id\n'
  fi
  exit 0
fi
if [ "${1:-}" = inspect ]; then
  [ -n "${FAKE_EXISTING_CONFIG:-}" ] || exit 1
  printf '%s\n' "$FAKE_EXISTING_CONFIG"
fi
if [ "${FAKE_SOURCE_VOLUMES:-}" = 1 ] && [ "${1:-}" = compose ]; then
  case " $* " in
    *' --project-name node-manager-apt '*) ;;
    *) exit 88 ;;
  esac
fi
case " $* " in
  *' config --images '*) printf 'example.invalid/stack:test\n' ;;
  *' image inspect '*) [ "${FAKE_IMAGES_MISSING:-0}" != 1 ] || [ -f "$FAKE_DOCKER_LOG.images-ready" ]; exit ;;
  *' pull '*) touch "$FAKE_DOCKER_LOG.images-ready" ;;
esac
EOF
chmod +x "$fake/docker"
cat >"$fake/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$FAKE_DOCKER_LOG"
EOF
chmod +x "$fake/systemctl"

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

: >"$log"
init_out=$(BITCOIN_STACK_DEFAULT_BIND_IP=192.168.1.116 FAKE_IMAGES_MISSING=1 "$wrapper" init)
[ "$(jq -r '.bitcoin.enabled' "$config_dir/config.json")" = true ] || fail "package init did not default to Bitcoin"
[ "$(jq -r '.bitcoin.resource_profile' "$config_dir/config.json")" = compact ] || fail "package init did not select the compact Bitcoin profile"
[ "$(jq -r '.dashboard.password' "$config_dir/config.json")" = "" ] || fail "package init did not default to a passwordless dashboard"
[ "$(jq -r '.dashboard.bind_ip' "$config_dir/config.json")" = auto ] || fail "package init did not preserve automatic LAN binding"
[ "$(jq -r '.dashboard.launch_at_boot' "$config_dir/config.json")" = false ] || fail "package init enabled launch at boot"
[ "$(jq -r '.bitcoin.data_dir // empty' "$config_dir/config.json")" = "" ] || fail "package init stored the default FHS data path"
jq -e '(.bitcoin | has("node_password") | not)' "$config_dir/config.json" >/dev/null || fail "package init stored generated credentials in config"
printf '%s' "$init_out" | grep -q 'Dashboard password — default off' || fail "package init did not report its passwordless default"
printf '%s' "$init_out" | grep -q 'Bitcoin RPC — username: admin  password:' || fail "package init did not print the Bitcoin credentials"
printf '%s' "$init_out" | grep -q 'Monero RPC' && fail "package init printed credentials for an unselected node"
printf '%s' "$init_out" | grep -qE 'Dashboard password \(|Nodes to run \(|data directory \[|Download missing containers' && fail "package init still prompts for setup answers"
grep -q -- 'compose .* pull' "$log" || fail "package init did not pull missing images"
grep -q -- 'compose .* up -d --pull never --no-build' "$log" || fail "package init start allows implicit pulls or builds"
grep -q 'systemctl enable --now bitcoin-starter-stack-resource-profile.timer' "$log" || fail "package init did not start the resource profile timer"
grep -q 'systemctl enable --now bitcoin-starter-stack-port-control.timer' "$log" || fail "package init did not start the LAN port-control timer"
grep -q 'systemctl enable --now bitcoin-starter-stack-node-control.timer' "$log" || fail "package init did not start the node-control timer"

env_file=$state_dir/.env
[ -f "$env_file" ] || fail "generated state is outside the package state directory"
grep -q '^DASHBOARD_PASSWORD=$' "$env_file" || fail "fresh package install enabled dashboard authentication"
grep -q '^DASHBOARD_BIND_IP=192.168.1.116$' "$env_file" || fail "fresh package install did not use the detected LAN address"
grep -q '^BITCOIN_RPC_USER=admin$' "$env_file" || fail "fresh package install did not generate the Bitcoin RPC user"
bitcoin_password=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$env_file")
printf '%s' "$bitcoin_password" | grep -qE '^[0-9a-f]{48}$' || fail "fresh package install did not generate a Bitcoin RPC password"
grep -q "^BITCOIN_DATA_DIR=$data_root/bitcoin$" "$env_file" || fail "data path is outside the package data directory"
grep -q '^BITCOIN_DBCACHE=128$' "$env_file" || fail "fresh package install dbcache default is not 128 MB"
grep -q '^BITCOIN_PRUNE=10000$' "$env_file" || fail "fresh package install is not pruned to 10000 MB"
grep -q '^BITCOIN_RPC_EXPOSE=0$' "$env_file" || fail "fresh package install exposed RPC"
grep -q '^MONERO_ENABLED=0$' "$env_file" || fail "fresh package install enabled Monero"
grep -q '^COMPOSE_PROFILES=bitcoin$' "$env_file" || fail "fresh package install did not select Bitcoin"
grep -q '^BITCOIN_RESOURCE_PROFILE=compact$' "$env_file" || fail "package init did not enable the compact Bitcoin profile"
grep -q '^MONERO_RESOURCE_PROFILE=off$' "$env_file" || fail "package init enabled the compact profile for an unselected node"
grep -q '^BITCOIN_STEADY_CPUS=1$' "$env_file" || fail "package init did not render the Bitcoin steady CPU default"
grep -q '^BITCOIN_STEADY_MEM_LIMIT_MB=2048$' "$env_file" || fail "package init did not render the Bitcoin steady memory default"
grep -q '^STACK_RESTART_POLICY=on-failure:5$' "$env_file" || fail "fresh package install enabled launch at boot"
grep -q '^COMPOSE_FILE=docker-compose.yml$' "$env_file" || fail "fresh package install enabled an optional Compose override"
grep -q "^STACK_ROOT=$runtime$" "$env_file" || fail "immutable payload path was not rendered"
wallets=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$env_file" | base64 -d)
[ "$wallets" = '[]' ] || fail "fresh pruned package seeded a wallet it cannot scan"
[ -d "$data_root/bitcoin" ] || fail "data directory was not created"
[ "$(stat -c %u "$data_root/bitcoin")" = 1000 ] || fail "data directory is not owned by the container uid"
[ "$(stat -c %a "$data_root/bitcoin")" = 700 ] || fail "data directory permissions are not private"
[ "$(stat -c %u "$data_root/zcash")" = 10001 ] || fail "Zcash data directory is not owned by the Zakura uid"
[ "$(stat -c %g "$data_root/zcash")" = 1000 ] || fail "Zcash data directory is not readable by the dashboard group"
[ "$(stat -c %a "$data_root/zcash")" = 750 ] || fail "Zcash data directory permissions block its runtime handoff"
[ ! -e "$home" ] || fail "package wrote configuration or data under HOME"
[ ! -e "$runtime/.env" ] || fail "package wrote state into /usr/lib payload"
grep -q -- "--project-directory $state_dir" "$log" || fail "Compose project directory is not package state"
grep -q '^COMPOSE_PROJECT_NAME=node-manager-apt$' "$env_file" || fail "fresh package did not persist its Compose identity"
grep -q -- "--project-name node-manager-apt" "$log" || fail "package Compose project is not isolated from source installs"
grep -q -- "--env-file $env_file" "$log" || fail "Compose did not use package state env"
grep -q -- "-f $runtime/docker-compose.yml up -d" "$log" || fail "Compose did not use immutable payload"
grep -q -- "-f $runtime/docker-compose.rpc.yml" "$log" && fail "default package startup loaded the RPC override"

preset_config_dir=$tmp/preset/etc/bitcoin-starter-stack
preset_state_dir=$tmp/preset/var/lib/bitcoin-starter-stack
preset_data_root=$preset_state_dir/data
mkdir -p "$preset_config_dir"
jq -nc --arg data_dir "$preset_data_root/custom-monero" \
  '{bitcoin:{enabled:false},monero:{enabled:true,data_dir:$data_dir,node_password:"presetmoneropassword123456789012"},dashboard:{password:"presetdashboardpassword",bind_ip:"192.168.1.118",launch_at_boot:true}}' \
  >"$preset_config_dir/config.json"
cp "$preset_config_dir/config.json" "$tmp/preset-config.before"
: >"$log"
BITCOIN_STACK_CONFIG_DIR=$preset_config_dir BITCOIN_STACK_STATE_DIR=$preset_state_dir BITCOIN_STACK_DATA_DIR=$preset_data_root \
  "$wrapper" init >/dev/null
cmp -s "$tmp/preset-config.before" "$preset_config_dir/config.json" || fail "package init replaced an explicit preset config"
grep -q '^COMPOSE_PROFILES=monero$' "$preset_state_dir/.env" || fail "package init replaced a preset node selection"
grep -q '^DASHBOARD_PASSWORD=presetdashboardpassword$' "$preset_state_dir/.env" || fail "package init replaced a preset dashboard password"
grep -q '^MONERO_RPC_PASSWORD=presetmoneropassword123456789012$' "$preset_state_dir/.env" || fail "package init replaced a preset node credential"
grep -q '^STACK_RESTART_POLICY=unless-stopped$' "$preset_state_dir/.env" || fail "package init replaced a preset launch setting"

sed -i 's/^BITCOIN_DBCACHE=.*/BITCOIN_DBCACHE=512/' "$env_file"
"$wrapper" apply >/dev/null
grep -q '^BITCOIN_DBCACHE=512$' "$env_file" || fail "existing package dbcache was replaced"

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
grep -q -- "--project-name node-manager-apt" "$log" || fail "package could reuse source-managed named volumes"

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

: >"$log"
FAKE_EXISTING_SERVICE=tari-wallet FAKE_EXISTING_CONFIG=/source/bitcoin-starter-stack/docker-compose.yml \
  "$wrapper" up >"$tmp/existing-tari-wallet.out" 2>&1 && fail "package startup replaced a source-managed Tari wallet container"
grep -q 'Existing tari-wallet container belongs to another installation' "$tmp/existing-tari-wallet.out" || fail "Tari wallet deployment refusal is unclear"
grep -q 'compose .* up ' "$log" && fail "Tari wallet deployment refusal reached Compose up"

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
