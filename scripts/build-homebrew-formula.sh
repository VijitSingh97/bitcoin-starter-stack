#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

usage() {
  echo "Usage: scripts/build-homebrew-formula.sh [--url RELEASE_URL] [--output FORMULA] ARCHIVE" >&2
  exit 2
}

release_url=
output=dist/Formula/bitcoin-starter-stack.rb
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)
      [ "$#" -ge 2 ] || usage
      release_url=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || usage
      output=$2
      shift 2
      ;;
    --*) usage ;;
    *)
      [ "$#" -eq 1 ] || usage
      archive=$1
      shift
      ;;
  esac
done

[ -n "${archive:-}" ] || usage
[ -f "$archive" ] || { echo "release archive not found: $archive" >&2; exit 1; }
contents=$(mktemp)
trap 'rm -f "$contents"' EXIT
tar -tzf "$archive" >"$contents" 2>/dev/null || {
  echo "release archive is not a readable tar.gz" >&2
  exit 1
}
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$contents"; then
  echo "release archive contains an unsafe path" >&2
  exit 1
fi
for required in \
  bitcoin-starter-stack/stack \
  bitcoin-starter-stack/configure.sh \
  bitcoin-starter-stack/VERSION \
  bitcoin-starter-stack/docker-compose.yml \
  bitcoin-starter-stack/docker-compose.tari-wallet.yml \
  bitcoin-starter-stack/build/dashboard/Dockerfile \
  bitcoin-starter-stack/build/bitcoin/bitcoin.conf \
  bitcoin-starter-stack/build/tari/config.toml \
  bitcoin-starter-stack/build/tari/entrypoint.sh \
  bitcoin-starter-stack/build/tari-wallet/Dockerfile \
  bitcoin-starter-stack/build/tari-wallet/go.mod \
  bitcoin-starter-stack/build/tari-wallet/launcher.go \
  bitcoin-starter-stack/build/tari-wallet/config.toml \
  bitcoin-starter-stack/build/zcash/zakurad.toml \
  bitcoin-starter-stack/build/zcash/healthcheck.sh \
  bitcoin-starter-stack/scripts/bitcoin-stack \
  bitcoin-starter-stack/scripts/node-control \
  bitcoin-starter-stack/scripts/node-port-control \
  bitcoin-starter-stack/scripts/node-resource-profile; do
  grep -Fxq "$required" "$contents" || {
    echo "release archive is missing $required" >&2
    exit 1
  }
done
version=${PACKAGE_VERSION:-$(cat VERSION)}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "VERSION must be plain semantic version" >&2
  exit 1
}
release_url=${release_url:-https://github.com/VijitSingh97/bitcoin-starter-stack/releases/download/v${version}/bitcoin-starter-stack.tar.gz}
case "$release_url" in
  https://* | file:///*) ;;
  *) echo "release URL must use https:// or an absolute file:// URL" >&2; exit 1 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  checksum=$(sha256sum "$archive" | awk '{print $1}')
else
  checksum=$(shasum -a 256 "$archive" | awk '{print $1}')
fi
case "$checksum" in
  '' | *[!0-9a-f]*) echo "could not calculate SHA-256" >&2; exit 1 ;;
esac
[ "${#checksum}" -eq 64 ] || { echo "could not calculate SHA-256" >&2; exit 1; }

escape_sed() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
version_escaped=$(escape_sed "$version")
url_escaped=$(escape_sed "$release_url")
checksum_escaped=$(escape_sed "$checksum")
mkdir -p "$(dirname "$output")"
sed -e "s|@VERSION@|$version_escaped|g" \
  -e "s|@RELEASE_URL@|$url_escaped|g" \
  -e "s|@SHA256@|$checksum_escaped|g" \
  Formula/bitcoin-starter-stack.rb.in >"$output"
echo "Wrote $output for v$version ($checksum)"
