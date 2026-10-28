#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

for tool in apt-ftparchive apt-get gpg; do
  command -v "$tool" >/dev/null || {
    echo "SKIP: test_apt.sh ($tool not installed)"
    exit 0
  }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export SOURCE_DATE_EPOCH=1700000000
export PACKAGE_VERSION=0.0.0test
export GNUPGHOME=$tmp/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key 'bitcoin-starter-stack package test' rsa2048 sign 0 >/dev/null 2>&1
APT_SIGNING_FINGERPRINT=$(gpg --batch --with-colons --fingerprint --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
export APT_SIGNING_FINGERPRINT
[ -n "$APT_SIGNING_FINGERPRINT" ] || fail "test signing key has no fingerprint"

scripts/build-deb.sh >/dev/null
scripts/build-apt.sh
gpg --verify public/InRelease >/dev/null 2>&1 || fail "InRelease signature did not verify"

state=$tmp/apt
mkdir -p "$state/lists/partial" "$state/download"
chmod 755 "$state"
cp -R public "$state/feed"
chmod -R a+rX "$state/feed"
printf 'deb [signed-by=%s/feed/bitcoin-starter-stack.asc] file:%s/feed ./\n' "$state" "$state" >"$state/sources.list"
options=(-o "Dir::Etc::sourcelist=$state/sources.list" -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$state/lists")
apt-get "${options[@]}" update >/dev/null
(cd "$state/download" && apt-get "${options[@]}" download bitcoin-starter-stack >/dev/null)

printf 'tampered' >>"$state/feed/bitcoin-starter-stack_${PACKAGE_VERSION}_all.deb"
rm -f "$state/download"/*.deb
if (cd "$state/download" && apt-get "${options[@]}" download bitcoin-starter-stack >/dev/null 2>&1); then
  fail "APT accepted a package that did not match signed metadata"
fi

other=$tmp/other-gnupg
mkdir -m 700 "$other"
GNUPGHOME=$other gpg --batch --passphrase '' --quick-generate-key 'wrong package key' rsa2048 sign 0 >/dev/null 2>&1
GNUPGHOME=$other gpg --batch --armor --export >"$state/wrong.asc"
mkdir -p "$state/wrong-lists/partial"
printf 'deb [signed-by=%s/wrong.asc] file:%s/feed ./\n' "$state" "$state" >"$state/wrong.list"
wrong_options=(-o "Dir::Etc::sourcelist=$state/wrong.list" -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$state/wrong-lists")
if apt-get "${wrong_options[@]}" update >/dev/null 2>&1; then
  fail "APT accepted a feed signed by an untrusted key"
fi

if APT_SIGNING_FINGERPRINT=0000000000000000000000000000000000000000 scripts/build-apt.sh >/dev/null 2>&1; then
  fail "feed builder accepted an unavailable signing fingerprint"
fi
echo "PASS: test_apt.sh"
