#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

version=${PACKAGE_VERSION:-$(cat VERSION)}
case "$version" in
  '' | [!0-9]* | *[!A-Za-z0-9.-]* | *[.-])
    echo "package version must be a Debian version and Docker-compatible tag: $version" >&2
    exit 1
    ;;
esac
if [ "${#version}" -gt 128 ]; then
  echo "package version exceeds Docker's 128-character tag limit" >&2
  exit 1
fi
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}
export SOURCE_DATE_EPOCH
package=$(mktemp -d)
trap 'rm -rf "$package"' EXIT
root=$package/usr/lib/bitcoin-starter-stack
docs=$package/usr/share/doc/bitcoin-starter-stack
share=$package/usr/share/bitcoin-starter-stack

install -d "$package/DEBIAN" "$package/usr/bin" "$root" "$docs/docs" "$share"
install -m 755 scripts/bitcoin-stack "$package/usr/bin/bitcoin-stack"
install -m 755 stack configure.sh "$root/"
install -m 755 scripts/node-resource-profile "$root/node-resource-profile"
install -m 755 scripts/node-port-control "$root/node-port-control"
install -d "$package/usr/lib/systemd/system"
install -m 644 packaging/systemd/bitcoin-starter-stack-resource-profile.service packaging/systemd/bitcoin-starter-stack-resource-profile.timer \
  packaging/systemd/bitcoin-starter-stack-port-control.service packaging/systemd/bitcoin-starter-stack-port-control.timer \
  "$package/usr/lib/systemd/system/"
install -m 644 docker-compose.yml docker-compose.rpc.yml docker-compose.monero-rpc.yml docker-compose.monero-zmq.yml VERSION .dockerignore "$root/"
printf '%s\n' "$version" >"$root/VERSION"
cp -R build "$root/"
rm -rf "$root/build/dashboard/tests" "$root/build/dashboard/parity" \
  "$root/build/dashboard/.pytest_cache" "$root/build/dashboard/__pycache__"
find "$root/build/dashboard" -name '*_test.go' -delete
find "$root/build/dashboard/static" -name '*.test.mjs' -delete
find "$root/build/dashboard" -name '*.pyc' -delete
rm -f "$root/build/dashboard/.coverage" "$root/build/dashboard/.coveragerc" \
  "$root/build/dashboard/package.json"
install -m 644 README.md CHANGELOG.md SECURITY.md "$docs/"
install -m 644 LICENSE "$docs/copyright"
for guide in README architecture configuration getting-started hardware nodes notifications operations privacy watch-only; do
  install -m 644 "docs/$guide.md" "$docs/docs/"
done
install -m 644 config.example.json "$share/"

cat >"$package/DEBIAN/control" <<CONTROL
Package: bitcoin-starter-stack
Version: $version
Section: utils
Priority: optional
Architecture: all
Maintainer: Vijit Singh <VijitSingh97@users.noreply.github.com>
Depends: bash, ca-certificates, curl, docker-ce | docker.io, docker-compose-plugin (>= 2.33.1) | docker-compose-v2 (>= 2.33.1) | docker-compose (>= 2.33.1), iproute2, jq, openssl, util-linux
Homepage: https://github.com/VijitSingh97/bitcoin-starter-stack
Description: Private cryptocurrency nodes routed over Tor
 Runs selected pruned nodes, Tor, and a local dashboard through Docker Compose.
 Configuration lives in /etc; generated state and node data live in /var/lib.
CONTROL

find "$package" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p dist
dpkg-deb --root-owner-group --build "$package" "dist/bitcoin-starter-stack_${version}_all.deb"
