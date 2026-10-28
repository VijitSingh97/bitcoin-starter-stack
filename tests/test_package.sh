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
export PACKAGE_VERSION=0.0.0test
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
deb="dist/bitcoin-starter-stack_${PACKAGE_VERSION}_all.deb"
cp "$deb" "$tmp/first.deb"
SOURCE_DATE_EPOCH=1700000000 scripts/build-deb.sh >/dev/null
cmp -s "$tmp/first.deb" "$deb" || fail "package build is not reproducible"

dpkg-deb -c "$deb" >"$tmp/contents"
[ "$(dpkg-deb -f "$deb" Version)" = "$PACKAGE_VERSION" ] || fail "package version override was ignored"
for required in \
  ./usr/bin/bitcoin-stack \
  ./usr/lib/bitcoin-starter-stack/stack \
  ./usr/lib/bitcoin-starter-stack/configure.sh \
  ./usr/lib/bitcoin-starter-stack/docker-compose.yml \
  ./usr/lib/bitcoin-starter-stack/build/dashboard/main.go \
  ./usr/lib/bitcoin-starter-stack/build/tor/torrc \
  ./usr/share/doc/bitcoin-starter-stack/README.md \
  ./usr/share/doc/bitcoin-starter-stack/docs/privacy.md; do
  grep -q " $required$" "$tmp/contents" || fail "package is missing $required"
done
if grep -Eq '/(tests|parity|experiments|images)/|_test\.go$|\.test\.mjs$|package\.json$|docs/releasing\.md$|\.(jpg|jpeg)$' "$tmp/contents"; then
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
privacy=$root/usr/share/doc/bitcoin-starter-stack/docs/privacy.md
grep -q '^expected=UNPUBLISHED$' "$privacy" || fail "unreleased feed key is not fail-closed"
grep -q -- '--proxy socks5h://172.29.0.25:9050 --noproxy' "$privacy" || fail "feed key download is not pinned to the Tor proxy"
grep -q -- 'gpg --batch --show-keys --with-colons' "$privacy" || fail "feed key fingerprint is not verified"
fake=$tmp/fake-bin
mkdir "$fake"
cat >"$fake/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
if [ "${1:-}" = inspect ]; then
  [ -n "${FAKE_EXISTING_CONFIG:-}" ] || exit 1
  printf '%s\n' "$FAKE_EXISTING_CONFIG"
fi
EOF
chmod +x "$fake/docker"

home=$tmp/home
config_home=$tmp/config
state_home=$tmp/state
data_home=$tmp/data
log=$tmp/docker.log
wrapper=$root/usr/bin/bitcoin-stack
runtime=$root/usr/lib/bitcoin-starter-stack
export HOME=$home XDG_CONFIG_HOME=$config_home XDG_STATE_HOME=$state_home XDG_DATA_HOME=$data_home
export BITCOIN_STACK_ROOT=$runtime FAKE_DOCKER_LOG=$log PATH=$fake:$PATH

"$wrapper" help | grep -q 'Usage: bitcoin-stack' || fail "package command help is wrong"
[ ! -e "$log" ] || fail "help invoked Docker"
out=$("$wrapper" upgrade)
printf '%s' "$out" | grep -q 'sudo apt install --only-upgrade bitcoin-starter-stack' || fail "upgrade omitted APT instructions"
[ ! -e "$log" ] || fail "package upgrade invoked Docker"

"$wrapper" apply >/dev/null
env_file=$state_home/bitcoin-starter-stack/.env
[ -f "$env_file" ] || fail "generated state is outside XDG_STATE_HOME"
grep -q "^BITCOIN_DATA_DIR=$data_home/bitcoin-starter-stack/bitcoin$" "$env_file" || fail "data path is outside XDG_DATA_HOME"
grep -q "^STACK_ROOT=$runtime$" "$env_file" || fail "immutable payload path was not rendered"
[ -d "$data_home/bitcoin-starter-stack/bitcoin" ] || fail "data directory was not created"
[ ! -e "$runtime/.env" ] || fail "package wrote state into /usr/lib payload"
grep -q -- "--project-directory $state_home/bitcoin-starter-stack" "$log" || fail "Compose project directory is not XDG state"
grep -q -- "--env-file $env_file" "$log" || fail "Compose did not use XDG state env"
grep -q -- "-f $runtime/docker-compose.yml up -d" "$log" || fail "Compose did not use immutable payload"

: >"$log"
FAKE_EXISTING_CONFIG=/source/bitcoin-starter-stack/docker-compose.yml "$wrapper" up >"$tmp/existing.out" 2>&1 && fail "package startup replaced a source-managed container"
grep -q 'belongs to another installation' "$tmp/existing.out" || fail "existing deployment refusal is unclear"
grep -q 'compose .* up ' "$log" && fail "existing deployment refusal reached Compose up"

mkdir -p "$config_home/bitcoin-starter-stack"
printf '%s\n' '{"dashboard":{"control":true}}' >"$config_home/bitcoin-starter-stack/config.json"
rm -f "$log"
"$wrapper" apply >"$tmp/control.out" 2>&1 && fail "APT mode accepted dashboard.control"
grep -q 'dashboard.control is unavailable' "$tmp/control.out" || fail "dashboard.control rejection is unclear"
[ ! -e "$log" ] || fail "rejected config invoked Docker"

bad=$tmp/not-a-directory
: >"$bad"
XDG_CONFIG_HOME=$bad "$wrapper" help >"$tmp/bad.out" 2>&1 && fail "non-directory XDG path was accepted"
grep -q 'is not a directory' "$tmp/bad.out" || fail "bad XDG path error is unclear"

rm -rf "$root"
[ -f "$env_file" ] || fail "package removal simulation deleted user state"
echo "PASS: test_package.sh"
