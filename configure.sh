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
[ -n "$rpc_user" ] || rpc_user="bitcoin"                       # conventional default username
[ -n "$rpc_password" ] || rpc_password=$(openssl rand -hex 24) # strong random

data_dir=$(get '.bitcoin.data_dir' './data/bitcoin')
dbcache=$(jq -r '.bitcoin.dbcache_mb // 3000' <<<"$config")
prune=$(jq -r '.bitcoin.prune_mb // 0' <<<"$config")
mem_limit_mb=$(jq -r '.bitcoin.mem_limit_mb // 0' <<<"$config")
inbound_onion=$(flag '.bitcoin.inbound_onion')
blockfilterindex=$(flag '.bitcoin.blockfilterindex')
sync_over_clearnet=$(flag '.bitcoin.sync_over_clearnet')
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

if [ "$sync_over_clearnet" = "1" ]; then
  echo "WARNING: sync_over_clearnet is ON — the initial sync connects to clearnet"
  echo "         peers directly, which EXPOSES YOUR HOME IP (the opposite of the"
  echo "         Tor-only default). Set it back to false and run ./stack apply once"
  echo "         synced to return to Tor-only."
fi

# bitcoind rejects prune targets between 1 and 549 MB
case "$prune" in *[!0-9]*) prune=-1 ;; esac
if [ "$prune" -lt 0 ] || { [ "$prune" -ne 0 ] && [ "$prune" -lt 550 ]; }; then
  echo "prune_mb must be 0 (full node) or at least 550."
  exit 1
fi

# Optional bitcoind container memory cap. 0 (default) = unlimited (Docker's
# default, i.e. today's behavior). A cap turns a bitcoind memory blowup into a
# contained restart instead of a whole-host OOM. Rendered as e.g. "5000m".
case "$mem_limit_mb" in *[!0-9]*)
  echo "mem_limit_mb must be a whole number of MB (0 = unlimited)."
  exit 1
  ;;
esac
if [ "$mem_limit_mb" = "0" ]; then
  bitcoin_mem_limit=0
else
  bitcoin_mem_limit="${mem_limit_mb}m"
  if [ "$mem_limit_mb" -le "$dbcache" ]; then
    echo "WARNING: mem_limit_mb ($mem_limit_mb) is not above dbcache_mb ($dbcache) — bitcoind may be OOM-killed and restart-loop. Leave ~1.5-2 GB headroom above dbcache."
  fi
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

# Displayed version: the release number when this checkout IS the tagged release
# (or an unpacked release tarball, which has no git), otherwise branch-commit so
# dev builds are identifiable rather than masquerading as the release.
version=$(cat VERSION 2>/dev/null || echo dev)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head=$(git rev-parse HEAD 2>/dev/null || echo)
  # ^{commit} dereferences the (annotated) release tag to its commit; without it
  # the tag-object sha never equals HEAD and every deploy looks like a dev build.
  tag=$(git rev-parse "v$version^{commit}" 2>/dev/null || echo)
  # diff-index checks tracked files only, so runtime files (.env, data/) don't
  # demote a clean release checkout to a dev build.
  if [ -n "$head" ] && [ "$head" = "$tag" ] && git diff-index --quiet HEAD -- 2>/dev/null; then
    stack_version="$version" # clean checkout of the release tag
  else
    # '/' is legal in a git branch name but not in a Docker image tag, and
    # STACK_VERSION is used as the compose image tag — sanitize so a branch like
    # feat/x doesn't render an invalid ghcr reference and break `docker compose`.
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')
    short=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
      stack_version="$branch-$short" # a named branch
    else
      stack_version="$short" # detached HEAD, not at the release tag
    fi
  fi
else
  stack_version="$version" # release tarball (no .git)
fi

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
BITCOIN_SYNC_OVER_CLEARNET=$sync_over_clearnet
BITCOIN_MEM_LIMIT=$bitcoin_mem_limit
DASHBOARD_PASSWORD=$dashboard_password
DASHBOARD_ONION=$dashboard_onion
TELEGRAM_BOT_TOKEN=$telegram_bot_token
TELEGRAM_CHAT_ID=$telegram_chat_id
HEALTHCHECKS_URL=$healthchecks_url
ALERT_NEW_BLOCK=$alert_new_block
NODE_NAME=$(hostname)
STACK_VERSION=$stack_version
WATCH_WALLETS_B64=$watch_wallets_b64
EOF
chmod 600 .env

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"

echo "Done. Start the stack with: ./stack up   (or: docker compose up -d)"
