#!/usr/bin/env bash
# configure.sh end-to-end: placeholder guard, .env rendering, permissions.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp configure.sh "$tmp/"

fail() {
  echo "FAIL: $1"
  exit 1
}

# 1. Refuses to run without a config.json
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "missing config.json was accepted"

# 2. Refuses to run with placeholder credentials
cp config.example.json "$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "placeholder config was accepted"

# 3. Refuses empty/missing credentials
echo '{"bitcoin": {"node_username": "u"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "missing password was accepted"

# 4. Refuses special characters in credentials (they'd hit shell/env-file layers)
# shellcheck disable=SC2016 # non-expansion of the backtick is the point
echo '{"bitcoin": {"node_username": "u", "node_password": "p`whoami`"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "special characters in password were accepted"

# 5. Happy path renders .env with defaults applied
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "myuser", "node_password": "mypass123"}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null

grep -q '^BITCOIN_RPC_USER=myuser$' "$tmp/.env" || fail "username not rendered"
grep -q '^BITCOIN_RPC_PASSWORD=mypass123$' "$tmp/.env" || fail "password not rendered"
grep -q '^BITCOIN_DATA_DIR=./data/bitcoin$' "$tmp/.env" || fail "data_dir default not applied"
grep -q '^BITCOIN_DBCACHE=3000$' "$tmp/.env" || fail "dbcache default not applied"
[ -d "$tmp/data/bitcoin" ] || fail "data dir not created"

# 6. .env is private
# shellcheck disable=SC2012 # fixed filename, ls is the portable way to read the mode string
perms=$(ls -l "$tmp/.env" | cut -c1-10)
[ "$perms" = "-rw-------" ] || fail ".env permissions are $perms, expected -rw-------"

# 7. Custom data_dir and dbcache are honored
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "data_dir": "./elsewhere", "dbcache_mb": 512}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DATA_DIR=./elsewhere$' "$tmp/.env" || fail "custom data_dir not rendered"
grep -q '^BITCOIN_DBCACHE=512$' "$tmp/.env" || fail "custom dbcache not rendered"
[ -d "$tmp/elsewhere" ] || fail "custom data dir not created"

echo "PASS: test_configure.sh"
