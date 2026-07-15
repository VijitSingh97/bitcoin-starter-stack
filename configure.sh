#!/usr/bin/env bash
# Render config.json into a gitignored .env for docker compose, and create the
# data directory. config.json is OPTIONAL: with none, everything uses sensible
# defaults and the internal RPC credentials are auto-generated — zero setup.
# Usually run for you by `./stack up`; safe to run directly and to re-run.
set -euo pipefail
cd "$(dirname "$0")"

for tool in jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required: sudo apt install $tool"
    exit 1
  }
done

# config.json is optional — default to an empty object so every field falls back.
config='{}'
[ -f config.json ] && config=$(cat config.json)

get() { jq -r "$1 // \"${2:-}\"" <<<"$config"; }
flag() { jq -r "if $1 == true then 1 else 0 end" <<<"$config"; }

# Internal RPC credentials — used only between the dashboard and bitcoind on the
# private Docker network; you never type or see these. Honour config.json if set,
# otherwise reuse whatever is already in .env (so re-running is idempotent),
# otherwise generate fresh strong random values.
rpc_user=$(get '.bitcoin.node_username')
rpc_password=$(get '.bitcoin.node_password')
[ -n "$rpc_user" ] || rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' .env 2>/dev/null || true)
[ -n "$rpc_password" ] || rpc_password=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' .env 2>/dev/null || true)
[ -n "$rpc_user" ] || rpc_user="rpc$(openssl rand -hex 8)"
[ -n "$rpc_password" ] || rpc_password=$(openssl rand -hex 24)

data_dir=$(get '.bitcoin.data_dir' './data/bitcoin')
dbcache=$(jq -r '.bitcoin.dbcache_mb // 3000' <<<"$config")
prune=$(jq -r '.bitcoin.prune_mb // 0' <<<"$config")
inbound_onion=$(flag '.bitcoin.inbound_onion')
blockfilterindex=$(flag '.bitcoin.blockfilterindex')
dashboard_password=$(get '.dashboard.password')
dashboard_onion=$(flag '.dashboard.onion')
telegram_bot_token=$(get '.notifications.telegram_bot_token')
telegram_chat_id=$(get '.notifications.telegram_chat_id')
healthchecks_url=$(get '.notifications.healthchecks_url')
alert_new_block=$(flag '.notifications.alert_new_block')
# Watch-only public keys travel as a base64 JSON blob so xpubs/descriptors
# pass through .env untouched (no quoting or $-expansion footguns).
watch_wallets_b64=$(jq -cj '.wallets // []' <<<"$config" | base64 | tr -d '\n')

case "$rpc_user$rpc_password$dashboard_password" in
  *[!a-zA-Z0-9]*)
    echo "Use only letters and numbers in node_username, node_password, and dashboard password."
    exit 1
    ;;
esac

# Notification values pass through .env — reject anything env-file-unsafe
case "$telegram_bot_token$telegram_chat_id$healthchecks_url" in
  *[\ \	\'\"\$]*)
    echo "Notification settings must not contain spaces, quotes, or \$."
    exit 1
    ;;
esac

if [ -n "$healthchecks_url" ]; then
  case "$healthchecks_url" in
    http://* | https://*) ;;
    *)
      echo "healthchecks_url must be a full URL (paste it from healthchecks.io)."
      exit 1
      ;;
  esac
fi

if [ "$dashboard_onion" = "1" ] && [ -z "$dashboard_password" ]; then
  echo "WARNING: dashboard.onion is enabled without dashboard.password —"
  echo "         anyone who learns the onion address can view the dashboard."
fi

# bitcoind rejects prune targets between 1 and 549 MB
case "$prune" in *[!0-9]*) prune=-1 ;; esac
if [ "$prune" -lt 0 ] || { [ "$prune" -ne 0 ] && [ "$prune" -lt 550 ]; }; then
  echo "prune_mb must be 0 (full node) or at least 550."
  exit 1
fi

# blockfilterindex needs the full chain — bitcoind refuses to start with pruning
if [ "$blockfilterindex" = "1" ] && [ "$prune" != "0" ]; then
  echo "blockfilterindex requires a full node (prune_mb: 0) — it can't run on a pruned node."
  exit 1
fi

# rpcauth = salted HMAC of the password (same scheme as Bitcoin Core's
# rpcauth.py), so the bitcoin container never holds the plaintext password.
# Salt and hash stay as separate hex values; the container assembles the
# user:salt$hash string itself (a literal $ in .env is a compose footgun).
rpcauth_salt=$(openssl rand -hex 16)
rpcauth_hash=$(printf '%s' "$rpc_password" | openssl dgst -sha256 -hmac "$rpcauth_salt" -r | cut -d' ' -f1)

cat >.env <<EOF
BITCOIN_RPC_USER=$rpc_user
BITCOIN_RPC_PASSWORD=$rpc_password
BITCOIN_RPCAUTH_SALT=$rpcauth_salt
BITCOIN_RPCAUTH_HASH=$rpcauth_hash
BITCOIN_DATA_DIR=$data_dir
BITCOIN_DBCACHE=$dbcache
BITCOIN_PRUNE=$prune
BITCOIN_INBOUND_ONION=$inbound_onion
BITCOIN_BLOCKFILTERINDEX=$blockfilterindex
DASHBOARD_PASSWORD=$dashboard_password
DASHBOARD_ONION=$dashboard_onion
TELEGRAM_BOT_TOKEN=$telegram_bot_token
TELEGRAM_CHAT_ID=$telegram_chat_id
HEALTHCHECKS_URL=$healthchecks_url
ALERT_NEW_BLOCK=$alert_new_block
NODE_NAME=$(hostname)
STACK_VERSION=$(cat VERSION 2>/dev/null || echo dev)
WATCH_WALLETS_B64=$watch_wallets_b64
EOF
chmod 600 .env

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"

echo "Done. Start the stack with: ./stack up   (or: docker compose up -d)"
