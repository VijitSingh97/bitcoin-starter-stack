#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

verify_downloaded_key() {
  file=$1
  expected=$2
  listing=$(gpg --batch --show-keys --with-colons "$file" 2>/dev/null) || return 1
  actual=$(awk -F: '
    $1 == "pub" { primary_keys++ }
    $1 == "fpr" && primary_fingerprint == "" { primary_fingerprint = $10 }
    END { print primary_keys ":" primary_fingerprint }
  ' <<<"$listing") || return 1
  [ "$actual" = "1:$expected" ]
}

command -v gpg >/dev/null || {
  echo "SKIP: test_apt.sh (gpg not installed)"
  exit 0
}

for guide in README.md docs/getting-started.md docs/privacy.md; do
  grep -Fq "listing=\$(gpg --batch --show-keys --with-colons \"\$key\") || {" "$guide" || fail "$guide does not reject GPG parse failures"
  grep -Fq 'primary_keys++' "$guide" || fail "$guide does not count primary keys"
  grep -Fq "1:\$expected" "$guide" || fail "$guide does not require exactly the expected primary key"
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

expected_only=$tmp/expected-only.asc
gpg --batch --armor --export "$APT_SIGNING_FINGERPRINT" >"$expected_only"
verify_downloaded_key "$expected_only" "$APT_SIGNING_FINGERPRINT" || fail "onboarding rejected the expected primary key"
if verify_downloaded_key "$expected_only" 0000000000000000000000000000000000000000; then
  fail "onboarding accepted the wrong primary fingerprint"
fi

gpg --batch --yes --pinentry-mode loopback --passphrase '' \
  --quick-add-key "$APT_SIGNING_FINGERPRINT" rsa2048 encrypt 0 >/dev/null 2>&1
expected_with_subkey=$tmp/expected-with-subkey.asc
gpg --batch --armor --export "$APT_SIGNING_FINGERPRINT" >"$expected_with_subkey"
verify_downloaded_key "$expected_with_subkey" "$APT_SIGNING_FINGERPRINT" || fail "onboarding rejected an expected key with a subkey"

gpg --batch --passphrase '' --quick-generate-key 'extra package test key' rsa2048 sign 0 >/dev/null 2>&1
EXTRA_FINGERPRINT=$(gpg --batch --with-colons --fingerprint --list-secret-keys 'extra package test key' | awk -F: '$1 == "fpr" {print $10; exit}')
combined=$tmp/combined.asc
gpg --batch --armor --export "$APT_SIGNING_FINGERPRINT" "$EXTRA_FINGERPRINT" >"$combined"
if verify_downloaded_key "$combined" "$APT_SIGNING_FINGERPRINT"; then
  fail "onboarding accepted an extra primary key"
fi
printf 'not a key\n' >"$tmp/malformed.asc"
if verify_downloaded_key "$tmp/malformed.asc" "$APT_SIGNING_FINGERPRINT"; then
  fail "onboarding accepted an unparseable key file"
fi
echo "PASS: APT onboarding key checks"

for tool in apt-ftparchive apt-get; do
  command -v "$tool" >/dev/null || {
    echo "SKIP: test_apt.sh feed checks ($tool not installed)"
    exit 0
  }
done

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
