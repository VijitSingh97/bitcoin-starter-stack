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
grep -q '^BITCOIN_RPC_USER=admin$' "$tmp/.env" || fail "RPC user default is not 'admin'"
grep -qE '^BITCOIN_RPC_PASSWORD=[a-zA-Z0-9]{16,}$' "$tmp/.env" || fail "RPC password not auto-generated"
rpc_password=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$tmp/.env")
dashboard_password=$(sed -n 's/^DASHBOARD_PASSWORD=//p' "$tmp/.env")
[ "$rpc_password" = "$dashboard_password" ] || fail "fresh install did not share the generated password"
grep -q '^COMPOSE_FILE=docker-compose.yml$' "$tmp/.env" || fail "zero-config install enabled an optional compose override"
grep -q '^BITCOIN_RPC_EXPOSE=0$' "$tmp/.env" || fail "LAN RPC exposure default is not off"
grep -q '^BITCOIN_RPC_BIND_IP=$' "$tmp/.env" || fail "LAN RPC bind default is not empty"
grep -q '^BITCOIN_RPC_PORT=8332$' "$tmp/.env" || fail "LAN RPC port default not applied"
grep -q '^BITCOIN_DBCACHE=128$' "$tmp/.env" || fail "fresh install dbcache default is not 128 MB"
grep -q '^BITCOIN_PRUNE=10000$' "$tmp/.env" || fail "fresh install prune default is not 10000 MB"
grep -q '^BITCOIN_INBOUND_ONION=0$' "$tmp/.env" || fail "fresh install inbound onion default is not off"
grep -q '^DASHBOARD_ONION=0$' "$tmp/.env" || fail "fresh install dashboard onion default is not off"
watch_b64=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$tmp/.env")
watch_json=$(printf '%s' "$watch_b64" | openssl base64 -d -A)
printf '%s' "$watch_json" | jq -e 'length == 1 and .[0].name == "Binance (public)" and .[0].key == "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo" and .[0].birthday == ""' >/dev/null ||
  fail "zero-config install did not seed the public Binance example"

# 2. Re-running keeps the same auto-generated credentials AND the rpcauth
#    salt/hash (idempotent). A rotating salt re-derives the hash every run, which
#    changes the bitcoin container's env and needlessly recreates bitcoind on
#    every apply/upgrade (5-min flush each time).
u1=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$tmp/.env")
p1=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$tmp/.env")
s1=$(sed -n 's/^BITCOIN_RPCAUTH_SALT=//p' "$tmp/.env")
h1=$(sed -n 's/^BITCOIN_RPCAUTH_HASH=//p' "$tmp/.env")
(cd "$tmp" && ./configure.sh) >/dev/null
u2=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$tmp/.env")
p2=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$tmp/.env")
s2=$(sed -n 's/^BITCOIN_RPCAUTH_SALT=//p' "$tmp/.env")
h2=$(sed -n 's/^BITCOIN_RPCAUTH_HASH=//p' "$tmp/.env")
if [ "$u1" != "$u2" ] || [ "$p1" != "$p2" ]; then
  fail "credentials changed on re-run (not idempotent)"
fi
if [ "$s1" != "$s2" ] || [ "$h1" != "$h2" ]; then
  fail "rpcauth salt/hash changed on re-run — would recreate bitcoind on every apply/upgrade"
fi

# Existing rendered settings remain authoritative when a new default is added.
legacy="$tmp/legacy"
mkdir "$legacy"
cp configure.sh "$legacy/"
printf 'BITCOIN_RPC_USER=bitcoin\nBITCOIN_RPC_PASSWORD=oldrpc\nDASHBOARD_PASSWORD=olddashboard\nBITCOIN_DBCACHE=3000\nBITCOIN_PRUNE=0\nBITCOIN_INBOUND_ONION=1\nDASHBOARD_ONION=1\n' >"$legacy/.env"
(cd "$legacy" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_RPC_USER=bitcoin$' "$legacy/.env" || fail "existing RPC username was replaced"
grep -q '^BITCOIN_RPC_PASSWORD=oldrpc$' "$legacy/.env" || fail "existing RPC password was replaced"
grep -q '^DASHBOARD_PASSWORD=olddashboard$' "$legacy/.env" || fail "existing dashboard password was forced to match RPC"
grep -q '^BITCOIN_DBCACHE=3000$' "$legacy/.env" || fail "existing dbcache was replaced by the fresh-install default"
grep -q '^BITCOIN_PRUNE=0$' "$legacy/.env" || fail "existing archival node was converted to pruning"
grep -q '^BITCOIN_INBOUND_ONION=1$' "$legacy/.env" || fail "existing inbound onion setting was disabled"
grep -q '^DASHBOARD_ONION=1$' "$legacy/.env" || fail "existing dashboard onion setting was disabled"

legacy_missing="$tmp/legacy-missing-prune"
mkdir "$legacy_missing"
cp configure.sh "$legacy_missing/"
printf 'BITCOIN_RPC_USER=bitcoin\nBITCOIN_RPC_PASSWORD=oldrpc\n' >"$legacy_missing/.env"
(cd "$legacy_missing" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DBCACHE=3000$' "$legacy_missing/.env" || fail "pre-dbcache environment did not retain the legacy 3000 MB default"
grep -q '^BITCOIN_PRUNE=0$' "$legacy_missing/.env" || fail "existing pre-prune environment was converted to pruning"

existing_custom="$tmp/existing-custom-dbcache"
mkdir "$existing_custom"
cp configure.sh "$existing_custom/"
printf 'BITCOIN_RPC_USER=bitcoin\nBITCOIN_RPC_PASSWORD=oldrpc\nBITCOIN_DBCACHE=512\n' >"$existing_custom/.env"
(cd "$existing_custom" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DBCACHE=512$' "$existing_custom/.env" || fail "custom existing dbcache was replaced"

echo '{"bitcoin":{"dbcache_mb":"256","prune_mb":0,"inbound_onion":false},"dashboard":{"onion":false}}' >"$legacy/config.json"
(cd "$legacy" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DBCACHE=256$' "$legacy/.env" || fail "explicit dbcache did not override the existing rendered value"
grep -q '^BITCOIN_PRUNE=0$' "$legacy/.env" || fail "explicit prune_mb=0 was not preserved"
grep -q '^BITCOIN_INBOUND_ONION=0$' "$legacy/.env" || fail "explicit inbound_onion=false was ignored"
grep -q '^DASHBOARD_ONION=0$' "$legacy/.env" || fail "explicit dashboard.onion=false was ignored"

echo '{"dashboard":{"password":""}}' >"$legacy/config.json"
(cd "$legacy" && ./configure.sh) >/dev/null
grep -q '^DASHBOARD_PASSWORD=$' "$legacy/.env" || fail "explicit empty dashboard password was ignored"

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
rm -f "$tmp/.env"
(cd "$tmp" && ./configure.sh) >/dev/null

grep -q '^BITCOIN_RPC_USER=myuser$' "$tmp/.env" || fail "username not rendered"
grep -q '^BITCOIN_RPC_PASSWORD=mypass123$' "$tmp/.env" || fail "password not rendered"
grep -q '^BITCOIN_DATA_DIR=./data/bitcoin$' "$tmp/.env" || fail "data_dir default not applied"
grep -q '^BITCOIN_DBCACHE=128$' "$tmp/.env" || fail "dbcache default not applied"
grep -q '^BITCOIN_PRUNE=10000$' "$tmp/.env" || fail "prune default not applied"
grep -q '^BITCOIN_INBOUND_ONION=0$' "$tmp/.env" || fail "inbound_onion should default off"
grep -q '^BITCOIN_BLOCKFILTERINDEX=0$' "$tmp/.env" || fail "blockfilterindex default not applied"
grep -q '^BITCOIN_RPC_EXPOSE=0$' "$tmp/.env" || fail "LAN RPC exposure default not applied"
grep -q '^COMPOSE_FILE=docker-compose.yml$' "$tmp/.env" || fail "default compose file selection is wrong"
grep -q '^DASHBOARD_PASSWORD=mypass123$' "$tmp/.env" || fail "fresh explicit password was not shared with dashboard"
grep -q '^DASHBOARD_ONION=0$' "$tmp/.env" || fail "dashboard onion default not applied"
grep -q '^DASHBOARD_BIND_IP=127.0.0.1$' "$tmp/.env" || fail "dashboard bind default not applied"
grep -q '^TELEGRAM_BOT_TOKEN=$' "$tmp/.env" || fail "telegram token default not applied"
grep -q '^HEALTHCHECKS_URL=$' "$tmp/.env" || fail "healthchecks default not applied"
grep -q '^ALERT_NEW_BLOCK=0$' "$tmp/.env" || fail "new-block alert default not applied"
grep -q '^NODE_NAME=' "$tmp/.env" || fail "node name not rendered"
watch_b64=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$tmp/.env")
printf '%s' "$watch_b64" | openssl base64 -d -A | jq -e '.[0].name == "Binance (public)"' >/dev/null ||
  fail "missing wallets must seed the public Binance example"
[ -d "$tmp/data/bitcoin" ] || fail "data dir not created"

# An explicit empty roster opts out of the public example.
echo '{"wallets": []}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
watch_b64=$(sed -n 's/^WATCH_WALLETS_B64=//p' "$tmp/.env")
[ "$(printf '%s' "$watch_b64" | openssl base64 -d -A)" = "[]" ] ||
  fail "explicit empty wallets did not opt out"

# A malformed roster fails before replacing a valid rendered environment.
cp "$tmp/.env" "$tmp/env.before"
echo '{"wallets": {"name": "not-an-array"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "non-array wallets were accepted"
cmp -s "$tmp/.env" "$tmp/env.before" || fail "invalid wallets changed .env"

for unsafe_key in \
  'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about' \
  'xprvPrivateMaterial' \
  'wpkh(xprvPrivateMaterial/0/*)'; do
  jq -n --arg key "$unsafe_key" '{wallets:[{name:"Rejected",key:$key}]}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >"$tmp/rejected.log" 2>&1 && fail "private or invalid configured wallet was accepted"
  cmp -s "$tmp/.env" "$tmp/env.before" || fail "rejected public-only wallet changed .env"
  grep -Fq "$unsafe_key" "$tmp/rejected.log" && fail "rejected wallet material leaked into output"
done

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
{"bitcoin": {"node_username": "u", "node_password": "longrpcpassword1234567890", "data_dir": "./elsewhere", "dbcache_mb": 512, "prune_mb": 550, "inbound_onion": true, "rpc_expose": true, "rpc_bind_ip": "192.168.1.118", "rpc_port": 18332},
 "dashboard": {"password": "dashpass1", "onion": true, "bind_ip": "192.168.1.117"},
 "notifications": {"telegram_bot_token": "123:abc-DEF", "telegram_chat_id": "-10042", "healthchecks_url": "https://hc-ping.com/uuid", "alert_new_block": true},
 "wallets": [{"name": "Cold storage", "key": "34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo", "birthday": "2021-01-01"}]}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_DATA_DIR=./elsewhere$' "$tmp/.env" || fail "custom data_dir not rendered"
grep -q '^BITCOIN_DBCACHE=512$' "$tmp/.env" || fail "custom dbcache not rendered"
grep -q '^BITCOIN_PRUNE=550$' "$tmp/.env" || fail "custom prune not rendered"
grep -q '^BITCOIN_INBOUND_ONION=1$' "$tmp/.env" || fail "inbound_onion=true not rendered as 1"
grep -q '^BITCOIN_RPC_EXPOSE=1$' "$tmp/.env" || fail "rpc_expose=true not rendered as 1"
grep -q '^BITCOIN_RPC_BIND_IP=192.168.1.118$' "$tmp/.env" || fail "RPC LAN bind not rendered"
grep -q '^BITCOIN_RPC_PORT=18332$' "$tmp/.env" || fail "RPC host port not rendered"
grep -q '^COMPOSE_FILE=docker-compose.yml:docker-compose.rpc.yml$' "$tmp/.env" || fail "RPC compose override not enabled"
grep -q '^DASHBOARD_PASSWORD=dashpass1$' "$tmp/.env" || fail "dashboard password not rendered"
grep -q '^DASHBOARD_ONION=1$' "$tmp/.env" || fail "dashboard onion not rendered"
grep -q '^DASHBOARD_BIND_IP=192.168.1.117$' "$tmp/.env" || fail "dashboard LAN bind not rendered"
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
cat >"$tmp/config.json" <<'EOF'
{"notifications": {"healthchecks_url": "http://hc-ping.com/uuid"}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "HTTP healthchecks_url was accepted"

# blockfilterindex: honored on an explicitly configured archival node, rejected on a pruned one
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "prune_mb": 0, "blockfilterindex": true}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_BLOCKFILTERINDEX=1$' "$tmp/.env" || fail "blockfilterindex=true not rendered as 1"
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"node_username": "u", "node_password": "p", "prune_mb": 550, "blockfilterindex": true}}
EOF
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "blockfilterindex was accepted on a pruned node"

# Legacy false is harmless, but true is rejected before the existing .env changes.
cat >"$tmp/config.json" <<'EOF'
{"bitcoin": {"sync_over_clearnet": true}}
EOF
cp "$tmp/.env" "$tmp/env.before"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "sync_over_clearnet=true was accepted"
cmp -s "$tmp/.env" "$tmp/env.before" || fail "rejected clearnet setting changed .env"
echo '{"bitcoin": {"sync_over_clearnet": false}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_SYNC_OVER_CLEARNET=' "$tmp/.env" && fail "legacy clearnet variable remains in .env"

# Dashboard publication is limited to loopback and RFC1918 IPv4 addresses.
for bind_ip in 127.0.0.2 10.1.2.3 172.16.0.1 172.31.255.254 192.168.50.4; do
  jq -n --arg ip "$bind_ip" '{dashboard:{bind_ip:$ip}}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null || fail "private dashboard bind $bind_ip was rejected"
done
for bind_ip in 0.0.0.0 8.8.8.8 172.15.0.1 172.32.0.1 192.169.1.1 ::1 127.0.0.1/24 999.1.1.1 010.0.0.1 192.168.001.1; do
  jq -n --arg ip "$bind_ip" '{dashboard:{bind_ip:$ip}}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "unsafe dashboard bind $bind_ip was accepted"
done
printf '{"dashboard":{"bind_ip":"127.0.0.1\\nDASHBOARD_PASSWORD=x"}}\n' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "newline dashboard bind was accepted"

echo '{"bitcoin":{"rpc_expose":true}}' >"$tmp/config.json"
cp "$tmp/.env" "$tmp/env.before"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "RPC exposure without a bind address was accepted"
cmp -s "$tmp/.env" "$tmp/env.before" || fail "invalid RPC exposure changed .env"
echo '{"bitcoin":{"node_password":"short","rpc_expose":true,"rpc_bind_ip":"192.168.1.117"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "short password was accepted for exposed RPC"
echo '{"bitcoin":{"node_password":"short"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null || fail "short internal-only RPC password was rejected"
rm -f "$tmp/.env"
for bind_ip in 10.1.2.3 172.16.0.1 172.31.255.254 192.168.50.4; do
  jq -n --arg ip "$bind_ip" '{bitcoin:{rpc_expose:true,rpc_bind_ip:$ip}}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null || fail "private RPC bind $bind_ip was rejected"
done
for bind_ip in '' 0.0.0.0 127.0.0.1 8.8.8.8 172.15.0.1 172.32.0.1 192.169.1.1 ::1 999.1.1.1 010.0.0.1; do
  jq -n --arg ip "$bind_ip" '{bitcoin:{rpc_expose:true,rpc_bind_ip:$ip}}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "unsafe RPC bind $bind_ip was accepted"
done
for rpc_port in 0 65536 -1 '"8332x"'; do
  printf '{"bitcoin":{"rpc_expose":true,"rpc_bind_ip":"192.168.1.117","rpc_port":%s}}\n' "$rpc_port" >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "unsafe RPC port $rpc_port was accepted"
done
jq -n '{bitcoin:{rpc_expose:true,rpc_bind_ip:"192.168.1.117",rpc_port:80},dashboard:{bind_ip:"192.168.1.117"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "RPC/dashboard host port conflict was accepted"

# inbound_onion defaults off; explicit true opts in
echo '{"bitcoin": {"inbound_onion": false}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_INBOUND_ONION=0$' "$tmp/.env" || fail "inbound_onion: false should render 0"
echo '{"bitcoin": {"inbound_onion": true}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_INBOUND_ONION=1$' "$tmp/.env" || fail "inbound_onion: true should render 1"

# mem_limit_mb: default 0 -> unlimited; a set value renders as "<n>m"; a value
# not above dbcache warns; non-numeric is rejected
rm -f "$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_MEM_LIMIT=0$' "$tmp/.env" || fail "mem_limit default should render 0 (unlimited)"
echo '{"bitcoin": {"mem_limit_mb": 5000, "dbcache_mb": 3000}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null
grep -q '^BITCOIN_MEM_LIMIT=5000m$' "$tmp/.env" || fail "mem_limit_mb: 5000 should render 5000m"
echo '{"bitcoin": {"mem_limit_mb": 2000, "dbcache_mb": 3000}}' >"$tmp/config.json"
out=$(cd "$tmp" && ./configure.sh)
echo "$out" | grep -qi "WARNING: mem_limit_mb" || fail "no warning when mem_limit_mb <= dbcache_mb"
echo '{"bitcoin": {"mem_limit_mb": "lots"}}' >"$tmp/config.json"
(cd "$tmp" && ./configure.sh) >/dev/null 2>&1 && fail "non-numeric mem_limit_mb was accepted"
rm -f "$tmp/config.json"

# 12. Preserved legacy passwordless onion dashboards still warn.
warn="$tmp/warn"
mkdir "$warn"
cp configure.sh "$warn/"
printf 'BITCOIN_RPC_USER=u\nBITCOIN_RPC_PASSWORD=p\nDASHBOARD_PASSWORD=\n' >"$warn/.env"
cat >"$warn/config.json" <<'EOF'
{"dashboard": {"onion": true}}
EOF
out=$(cd "$warn" && ./configure.sh)
echo "$out" | grep -q "WARNING" || fail "no warning for onion dashboard without password"

# 13. Version string: release number for a clean tagged checkout, branch-commit
#     for a dev build (drives the dashboard's version display).
if command -v git >/dev/null; then
  gtmp=$(mktemp -d)
  cp configure.sh "$gtmp/"
  printf '9.9.9\n' >"$gtmp/VERSION"
  (
    cd "$gtmp"
    git init -q && git config user.email t@t && git config user.name t
    git add -A && git commit -qm init
    git tag -a v9.9.9 -m "Release v9.9.9" # annotated, exactly as scripts/release.sh does
    ./configure.sh >/dev/null
    grep -q '^STACK_VERSION=9.9.9$' .env || {
      echo "FAIL: tagged checkout should show release number"
      exit 1
    }
    # detached HEAD at the tag (how a box deploys: git checkout v9.9.9) is still official
    git checkout -q v9.9.9
    ./configure.sh >/dev/null
    grep -q '^STACK_VERSION=9.9.9$' .env || {
      echo "FAIL: detached checkout of the tag should show release number"
      exit 1
    }
    git checkout -qb feature && git commit -q --allow-empty -m more
    ./configure.sh >/dev/null
    grep -qE '^STACK_VERSION=feature-[0-9a-f]{7,}$' .env || {
      echo "FAIL: dev build should show branch-commit"
      exit 1
    }
    # a slashed branch name must NOT produce a slash (invalid Docker image tag,
    # since STACK_VERSION is the compose image tag)
    git checkout -qb feat/thing && git commit -q --allow-empty -m more
    ./configure.sh >/dev/null
    grep -qE '^STACK_VERSION=feat-thing-[0-9a-f]{7,}$' .env || {
      echo "FAIL: slashed branch should render as feat-thing-<hash>, got: $(grep '^STACK_VERSION=' .env)"
      exit 1
    }
  ) || exit 1
  rm -rf "$gtmp"
fi

# The zero-config .env must render a valid compose config (what `./stack up` runs)
if command -v docker >/dev/null; then
  rm -f "$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null
  docker compose --env-file "$tmp/.env" config >/dev/null 2>&1 ||
    fail "zero-config .env does not render a valid compose config"
  echo '{"bitcoin":{"node_password":"longrpcpassword1234567890","rpc_expose":true,"rpc_bind_ip":"192.168.1.117","rpc_port":18332}}' >"$tmp/config.json"
  (cd "$tmp" && ./configure.sh) >/dev/null
  rpc_rendered=$(docker compose --env-file "$tmp/.env" config)
  echo "$rpc_rendered" | grep -A5 'target: 8332' | grep -q 'published: "18332"' ||
    fail "rendered COMPOSE_FILE did not select the RPC override"
fi

echo "PASS: test_configure.sh"
