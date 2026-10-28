#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

version=${PACKAGE_VERSION:-$(cat VERSION)}
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
install -m 644 docker-compose.yml VERSION .dockerignore "$root/"
cp -R build "$root/"
rm -rf "$root/build/dashboard/tests" "$root/build/dashboard/parity"
find "$root/build/dashboard" -name '*_test.go' -delete
find "$root/build/dashboard/static" -name '*.test.mjs' -delete
rm -f "$root/build/dashboard/.coveragerc" "$root/build/dashboard/package.json"
install -m 644 README.md CHANGELOG.md SECURITY.md "$docs/"
install -m 644 LICENSE "$docs/copyright"
for guide in README architecture configuration getting-started hardware notifications operations privacy watch-only; do
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
Depends: bash, ca-certificates, curl, docker-ce | docker.io, docker-compose-plugin (>= 2.33.1) | docker-compose-v2 (>= 2.33.1) | docker-compose (>= 2.33.1), jq, openssl
Homepage: https://github.com/VijitSingh97/bitcoin-starter-stack
Description: Private Bitcoin full node routed over Tor
 Runs Bitcoin Core, Tor, and a local dashboard through Docker Compose.
 Configuration and node data remain in the installing user's XDG directories.
CONTROL

find "$package" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
mkdir -p dist
dpkg-deb --root-owner-group --build "$package" "dist/bitcoin-starter-stack_${version}_all.deb"
