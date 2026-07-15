#!/usr/bin/env bash
# configure.sh end-to-end: zero-config auto-generation, .env rendering, validation.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp configure.sh "$tmp/"

fail() {
  echo "FAIL: $1"
  exit 1
}

# 1. Runs with NO config.json — defaults applied, RPC credentials auto-generated
(cd "$tmp" && ./configure.sh) >/dev/null || fail "zero-config run failed"
grep -q '^BITCOIN_RPC_USER=bitcoin$' "$tmp/.env" || fail "RPC user default is not 'bitcoin'"
grep -qE '^BITCOIN_RPC_PASSWORD=[a-zA-Z0-9]{16,}$' "$tmp/.env" || fail "RPC password not auto-generated"
grep -q '^BITCOIN_PRUNE=0$' "$tmp/.env" || fail "prune default not applied without config"

# 2. Re-running keeps the same auto-generated credentials (idempotent)
u1=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$tmp/.env")
p1=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$tmp/.env")
(cd "$tmp" && ./configure.sh) >/dev/null
u2=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$tmp/.env")
p2=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$tmp/.env")
if [ "$u1" != "$u2" ] || [ "$p1" != "$p2" ]; then
  fail "credentials changed on re-run (not idempotent)"
fi

# 3. A config.json without credentials still gets auto-generated ones
rm -f "$tmp/.env"
echo '{"bitcoin": {"dbcache_mb": 512}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -qE '^BITCOIN_RPC_USER=[a-zA-Z0-9]+$' "$tmp/.env" || fail "creds not auto-generated with partial config"
grep -q '^BITCOIN_DBCACHE=512$' "$tmp/.env" || fail "partial config override not applied"

# 4. Refuses special characters in credentials (they'd hit shell/env-file layers)
# shellcheck disable=SC2016 # non-expansion of the backtick is the point
echo '{"bitcoin": {"node_username": "u", "node_password": "p`whoami`"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "special characters in password were accepted"

# 5. Refuses prune targets bitcoind would reject (1-549) and non-numbers
echo '{"bitcoin": {"node_username": "u", "node_password": "p", "prune_mb": 100}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "prune_mb=100 was accepted"
echo '{"bitcoin": {"node_username": "u", "node_password": "p", "prune_mb": "lots"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "non-numeric prune_mb was accepted"

# 6. Refuses special characters in the dashboard password too
echo '{"bitcoin": {"node_username": "u", "node_password": "p"}, "dashboard": {"password": "a b"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "special characters in dashboard password were accepted"

# 7. Happy path renders .env with defaults applied
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "myuser", "node_password": "mypass123"}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null

grep -q '^BITCOIN_RPC_USER=myuser$' "$tmp/.env" || fail "username not rendered"
grep -q '^BITCOIN_RPC_PASSWORD=mypass123$' "$tmp/.env" || fail "password not rendered"
grep -q '^BITCOIN_DATA_DIR=./data/bitcoin$' "$tmp/.env" || fail "data_dir default not applied"
grep -q '^BITCOIN_DBCACHE=3000$' "$tmp/.env" || fail "dbcache default not applied"
grep -q '^BITCOIN_PRUNE=0$' "$tmp/.env" || fail "prune default not applied"
grep -q '^BITCOIN_INBOUND_ONION=0$' "$tmp/.env" || fail "inbound_onion default not applied"
grep -q '^BITCOIN_BLOCKFILTERINDEX=0$' "$tmp/.env" || fail "blockfilterindex default not applied"
grep -q '^DASHBOARD_PASSWORD=$' "$tmp/.env" || fail "dashboard password default not applied"
grep -q '^DASHBOARD_ONION=0$' "$tmp/.env" || fail "dashboard onion default not applied"
grep -q '^TELEGRAM_BOT_TOKEN=$' "$tmp/.env" || fail "telegram token default not applied"
grep -q '^HEALTHCHECKS_URL=$' "$tmp/.env" || fail "healthchecks default not applied"
grep -q '^ALERT_NEW_BLOCK=0$' "$tmp/.env" || fail "new-block alert default not applied"
grep -q '^NODE_NAME=' "$tmp/.env" || fail "node name not rendered"
grep -q '^WATCH_WALLETS_B64=W10=$' "$tmp/.env" || fail "empty wallets not rendered as base64 []"
[ -d "$tmp/data/bitcoin" ] || fail "data dir not created"

# 8. rpcauth is a real salted HMAC of the password (re-derive to check)
salt=$(sed -n 's/^BITCOIN_RPCAUTH_SALT=//p' "$tmp/.env")
hash=$(sed -n 's/^BITCOIN_RPCAUTH_HASH=//p' "$tmp/.env")
echo "$salt" | grep -qE '^[0-9a-f]{32}$' || fail "rpcauth salt is not 32 hex chars: $salt"
expected=$(printf '%s' "mypass123" | openssl dgst -sha256 -hmac "$salt" -r | cut -d' ' -f1)
[ "$hash" = "$expected" ] || fail "rpcauth hash does not verify against the password"

# 9. .env is private
# shellcheck disable=SC2012 # fixed filename, ls is the portable way to read the mode string
perms=$(ls -l "$tmp/.env" | cut -c1-10)
[ "$perms" = "-rw-------" ] || fail ".env permissions are $perms, expected -rw-------"

# 10. Custom values are honored
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "data_dir": "./elsewhere", "dbcache_mb": 512, "prune_mb": 550, "inbound_onion": true},
 "dashboard": {"password": "dashpass1", "onion": true},
 "notifications": {"telegram_bot_token": "123:abc-DEF", "telegram_chat_id": "-10042", "healthchecks_url": "https://hc-ping.com/uuid", "alert_new_block": true},
 "wallets": [{"name": "Cold storage", "key": "zpub6rFR7", "birthday": "2021-01-01"}]}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DATA_DIR=./elsewhere$' "$tmp/.env" || fail "custom data_dir not rendered"
grep -q '^BITCOIN_DBCACHE=512$' "$tmp/.env" || fail "custom dbcache not rendered"
grep -q '^BITCOIN_PRUNE=550$' "$tmp/.env" || fail "custom prune not rendered"
grep -q '^BITCOIN_INBOUND_ONION=1$' "$tmp/.env" || fail "inbound_onion=true not rendered as 1"
grep -q '^DASHBOARD_PASSWORD=dashpass1$' "$tmp/.env" || fail "dashboard password not rendered"
grep -q '^DASHBOARD_ONION=1$' "$tmp/.env" || fail "dashboard onion not rendered"
grep -q '^TELEGRAM_BOT_TOKEN=123:abc-DEF$' "$tmp/.env" || fail "telegram token not rendered"
grep -q '^TELEGRAM_CHAT_ID=-10042$' "$tmp/.env" || fail "telegram chat id not rendered"
grep -q '^HEALTHCHECKS_URL=https://hc-ping.com/uuid$' "$tmp/.env" || fail "healthchecks url not rendered"
grep -q '^ALERT_NEW_BLOCK=1$' "$tmp/.env" || fail "new-block alert not rendered"
# wallets round-trip through the base64 blob (decode and check the name survived)
watch_b64=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$tmp/.env")
printf '%s' "$watch_b64" | openssl base64 -d -A | grep -q '"name":"Cold storage"' ||
  fail "wallets not rendered into WATCH_WALLETS_B64"
[ -d "$tmp/elsewhere" ] || fail "custom data dir not created"

# 11. Rejects env-file-unsafe notification values and non-URL healthchecks
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p"},
 "notifications": {"telegram_bot_token": "has space"}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "telegram token with a space was accepted"
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p"},
 "notifications": {"healthchecks_url": "hc-ping.com/uuid"}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "non-URL healthchecks_url was accepted"

# blockfilterindex: honored on a full node, rejected on a pruned one
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "blockfilterindex": true}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_BLOCKFILTERINDEX=1$' "$tmp/.env" || fail "blockfilterindex=true not rendered as 1"
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "prune_mb": 550, "blockfilterindex": true}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "blockfilterindex was accepted on a pruned node"

# 12. Warns when the onion dashboard has no password
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p"}, "dashboard": {"onion": true}}
EOF
out=$(cd "$tmp" && ./configure.sh)
echo "$out" | grep -q "WARNING" || fail "no warning for onion dashboard without password"

# The zero-config .env must render a valid compose config (what `./stack up` runs)
if command -v docker >/dev/null; then
  rm -f "$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null
  docker compose --env-file "$tmp/.env" config >/dev/null 2>&1 ||
    fail "zero-config .env does not render a valid compose config"
fi

echo "PASS: test_configure.sh"
