#!/usr/bin/env bash
# Render config.json into a gitignored .env for docker compose, and create the
# data directory. config.json is OPTIONAL: with none, everything uses sensible
# defaults and the internal RPC credentials are auto-generated — zero setup.
# Usually run for you by `./stack up`; safe to run directly and to re-run.
set -euo pipefail
stack_root=${BITCOIN_STACK_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_dir=${BITCOIN_STACK_STATE_DIR:-$stack_root}
config_dir=${BITCOIN_STACK_CONFIG_DIR:-$state_dir}
config_file=$config_dir/config.json
env_file=$state_dir/.env
stack_command=${BITCOIN_STACK_COMMAND:-./stack}
package_managed=${BITCOIN_STACK_PACKAGE_MANAGED:-0}
mkdir -p "$state_dir" "$config_dir"
cd "$state_dir"

for tool in jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required; see docs/privacy.md for Tor-routed dependency installation."
    exit 1
  }
done

# config.json is optional — default to an empty object so every field falls back.
config='{}'
[ -f "$config_file" ] && config=$(cat "$config_file")

get() { jq -r "$1 // \"${2:-}\"" <<<"$config"; }
flag() { jq -r "if $1 == true then 1 else 0 end" <<<"$config"; }

# Internal RPC credentials — used only between the dashboard and bitcoind on the
# private Docker network; you never type or see these. Honour config.json if set,
# otherwise reuse whatever is already in .env (so re-running is idempotent),
# otherwise generate fresh strong random values.
rpc_user=$(get '.bitcoin.node_username')
rpc_password=$(get '.bitcoin.node_password')
[ -n "$rpc_user" ] || rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$env_file" 2>/dev/null || true)
[ -n "$rpc_password" ] || rpc_password=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$env_file" 2>/dev/null || true)
[ -n "$rpc_user" ] || rpc_user="bitcoin"                       # conventional default username
[ -n "$rpc_password" ] || rpc_password=$(openssl rand -hex 24) # strong random

data_dir=$(get '.bitcoin.data_dir')
if [ -z "$data_dir" ]; then
  if [ -n "${BITCOIN_STACK_DATA_DIR:-}" ]; then
    data_dir=$BITCOIN_STACK_DATA_DIR/bitcoin
  else
    data_dir=./data/bitcoin
  fi
fi
dbcache=$(jq -r '.bitcoin.dbcache_mb // 3000' <<<"$config")
if jq -e '(.bitcoin? // {}) | has("prune_mb")' >/dev/null <<<"$config"; then
  prune=$(jq -r '.bitcoin.prune_mb' <<<"$config")
elif [ "$package_managed" = "1" ]; then
  prune=$(sed -n 's/^BITCOIN_PRUNE=//p' "$env_file" 2>/dev/null || true)
  if [ -z "$prune" ]; then
    prune=10000
  fi
else
  prune=0
fi
mem_limit_mb=$(jq -r '.bitcoin.mem_limit_mb // 0' <<<"$config")
# default ON (encouraged): accept inbound over Tor unless explicitly disabled
inbound_onion=$(jq -r 'if .bitcoin.inbound_onion == false then 0 else 1 end' <<<"$config")
blockfilterindex=$(flag '.bitcoin.blockfilterindex')
rpc_expose=$(flag '.bitcoin.rpc_expose')
rpc_bind_ip=$(get '.bitcoin.rpc_bind_ip')
rpc_port=$(jq -r '.bitcoin.rpc_port // 8332' <<<"$config")
dashboard_password=$(get '.dashboard.password')
dashboard_onion=$(flag '.dashboard.onion')
dashboard_control=$(flag '.dashboard.control')
dashboard_bind_ip=$(get '.dashboard.bind_ip' '127.0.0.1')
telegram_bot_token=$(get '.notifications.telegram_bot_token')
telegram_chat_id=$(get '.notifications.telegram_chat_id')
healthchecks_url=$(get '.notifications.healthchecks_url')
alert_new_block=$(flag '.notifications.alert_new_block')
if [ "$package_managed" = "1" ] && [ "$dashboard_control" = "1" ]; then
  echo "dashboard.control is unavailable for APT installations; use $stack_command backup, apt upgrade, then $stack_command apply." >&2
  exit 1
fi
# Watch-only public keys travel as a base64 JSON blob so xpubs/descriptors
# pass through .env untouched (no quoting or $-expansion footguns).
default_wallets='[{"name":"Binance (public)","key":"34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo","birthday":""}]'
if [ "$package_managed" = "1" ] && [ "$prune" != "0" ]; then
  default_wallets='[]'
fi
watch_wallets_b64=$(jq -cej --argjson defaults "$default_wallets" 'if has("wallets") then if (.wallets | type) == "array" then .wallets else error("wallets must be an array") end else $defaults end' <<<"$config" | base64 | tr -d '\n')

check_alnum() {
  case "$2" in
  *[!a-zA-Z0-9]*)
    echo "$1 must contain only letters and numbers."
    exit 1
    ;;
  esac
}
check_alnum "node_username" "$rpc_user"
check_alnum "node_password" "$rpc_password"
check_alnum "dashboard password" "$dashboard_password"

if [ "$rpc_expose" = "1" ] && ((${#rpc_password} < 24)); then
  echo "bitcoin.node_password must be at least 24 characters when bitcoin.rpc_expose is true."
  exit 1
fi

check_bind_ip() {
  local field=$1 ip=$2 allow_loopback=$3 a b c d octet expected="a private IPv4 address"
  [ "$allow_loopback" = "1" ] && expected="a loopback or private IPv4 address"
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "$field must be $expected."
    exit 1
  fi
  IFS=. read -r a b c d <<<"$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    if { ((${#octet} > 1)) && [[ "$octet" == 0* ]]; } || ((10#$octet > 255)); then
      echo "$field must be $expected."
      exit 1
    fi
  done
  if ! (((allow_loopback == 1 && 10#$a == 127) || 10#$a == 10 || (10#$a == 172 && 10#$b >= 16 && 10#$b <= 31) || (10#$a == 192 && 10#$b == 168))); then
    echo "$field must be $expected."
    exit 1
  fi
}
check_bind_ip dashboard.bind_ip "$dashboard_bind_ip" 1

if [ -n "$rpc_bind_ip" ]; then
  check_bind_ip bitcoin.rpc_bind_ip "$rpc_bind_ip" 0
elif [ "$rpc_expose" = "1" ]; then
  echo "bitcoin.rpc_bind_ip is required when bitcoin.rpc_expose is true."
  exit 1
fi
case "$rpc_port" in '' | *[!0-9]*)
  echo "bitcoin.rpc_port must be a whole number from 1 to 65535."
  exit 1
  ;;
esac
if ((10#$rpc_port < 1 || 10#$rpc_port > 65535)); then
  echo "bitcoin.rpc_port must be a whole number from 1 to 65535."
  exit 1
fi
if [ "$rpc_expose" = "1" ] && [ "$rpc_bind_ip" = "$dashboard_bind_ip" ] && [ "$rpc_port" = "80" ]; then
  echo "bitcoin.rpc_port conflicts with the dashboard on $rpc_bind_ip:80."
  exit 1
fi

compose_file=docker-compose.yml
[ "$rpc_expose" = "1" ] && compose_file=docker-compose.yml:docker-compose.rpc.yml

if jq -e '.bitcoin.sync_over_clearnet == true' >/dev/null <<<"$config"; then
  echo "bitcoin.sync_over_clearnet is no longer supported; all public internet traffic must use Tor."
  exit 1
fi

# Notification values pass through .env — reject anything env-file-unsafe
check_envsafe() {
  case "$2" in
  *[\ \	\'\"\$]*)
    echo "$1 must not contain spaces, quotes, or \$."
    exit 1
    ;;
  esac
}
check_envsafe "telegram_bot_token" "$telegram_bot_token"
check_envsafe "telegram_chat_id" "$telegram_chat_id"
check_envsafe "healthchecks_url" "$healthchecks_url"

if [ -n "$healthchecks_url" ]; then
  case "$healthchecks_url" in
  https://*) ;;
  *)
    echo "healthchecks_url must be a full HTTPS URL (paste it from healthchecks.io)."
    exit 1
    ;;
  esac
fi

if [ "$dashboard_onion" = "1" ] && [ -z "$dashboard_password" ]; then
  echo "WARNING: dashboard.onion is enabled without dashboard.password —"
  echo "         anyone who learns the onion address can view the dashboard."
fi

if [ "$dashboard_control" = "1" ] && [ -z "$dashboard_password" ]; then
  echo "WARNING: dashboard.control is enabled without dashboard.password —"
  echo "         set a password so only you can trigger upgrades from the dashboard."
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
# Reuse the existing salt (like the password above) so an unchanged password
# re-renders byte-identical — a fresh salt every run would rotate the hash and
# needlessly recreate the bitcoin container on every apply/upgrade.
rpcauth_salt=$(sed -n 's/^BITCOIN_RPCAUTH_SALT=//p' "$env_file" 2>/dev/null || true)
[ -n "$rpcauth_salt" ] || rpcauth_salt=$(openssl rand -hex 16)
rpcauth_hash=$(printf '%s' "$rpc_password" | openssl dgst -sha256 -hmac "$rpcauth_salt" -r | cut -d' ' -f1)

# Displayed version: the release number when this checkout IS the tagged release
# (or an unpacked release tarball, which has no git), otherwise branch-commit so
# dev builds are identifiable rather than masquerading as the release.
version=$(cat "$stack_root/VERSION" 2>/dev/null || echo dev)
if git -C "$stack_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head=$(git -C "$stack_root" rev-parse HEAD 2>/dev/null || echo)
  # ^{commit} dereferences the (annotated) release tag to its commit; without it
  # the tag-object sha never equals HEAD and every deploy looks like a dev build.
  tag=$(git -C "$stack_root" rev-parse "v$version^{commit}" 2>/dev/null || echo)
  # diff-index checks tracked files only, so runtime files (.env, data/) don't
  # demote a clean release checkout to a dev build.
  if [ -n "$head" ] && [ "$head" = "$tag" ] && git -C "$stack_root" diff-index --quiet HEAD -- 2>/dev/null; then
    stack_version="$version" # clean checkout of the release tag
  else
    # '/' is legal in a git branch name but not in a Docker image tag, and
    # STACK_VERSION is used as the compose image tag — sanitize so a branch like
    # feat/x doesn't render an invalid ghcr reference and break `docker compose`.
    branch=$(git -C "$stack_root" rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')
    short=$(git -C "$stack_root" rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
      stack_version="$branch-$short" # a named branch
    else
      stack_version="$short" # detached HEAD, not at the release tag
    fi
  fi
else
  stack_version="$version" # release tarball (no .git)
fi

cat >"$env_file" <<EOF
COMPOSE_FILE=$compose_file
BITCOIN_RPC_USER=$rpc_user
BITCOIN_RPC_PASSWORD=$rpc_password
BITCOIN_RPCAUTH_SALT=$rpcauth_salt
BITCOIN_RPCAUTH_HASH=$rpcauth_hash
BITCOIN_RPC_EXPOSE=$rpc_expose
BITCOIN_RPC_BIND_IP=$rpc_bind_ip
BITCOIN_RPC_PORT=$rpc_port
BITCOIN_DATA_DIR=$data_dir
BITCOIN_DBCACHE=$dbcache
BITCOIN_PRUNE=$prune
BITCOIN_INBOUND_ONION=$inbound_onion
BITCOIN_BLOCKFILTERINDEX=$blockfilterindex
BITCOIN_MEM_LIMIT=$bitcoin_mem_limit
DASHBOARD_PASSWORD=$dashboard_password
DASHBOARD_ONION=$dashboard_onion
DASHBOARD_CONTROL=$dashboard_control
DASHBOARD_BIND_IP=$dashboard_bind_ip
TELEGRAM_BOT_TOKEN=$telegram_bot_token
TELEGRAM_CHAT_ID=$telegram_chat_id
HEALTHCHECKS_URL=$healthchecks_url
ALERT_NEW_BLOCK=$alert_new_block
NODE_NAME=$(hostname)
STACK_VERSION=$stack_version
STACK_ROOT=$stack_root
WATCH_WALLETS_B64=$watch_wallets_b64
EOF
chmod 600 "$env_file"

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"
if [ "$package_managed" = "1" ] && [ "$data_dir" = "${BITCOIN_STACK_DATA_DIR%/}/bitcoin" ]; then
  chown 1000:1000 "$data_dir"
  chmod 700 "$data_dir"
fi

echo "Done. Start preloaded images with: $stack_command up (downloads: $stack_command pull; see docs/privacy.md)."
