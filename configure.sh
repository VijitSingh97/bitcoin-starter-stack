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
umask 077
mkdir -p "$state_dir" "$config_dir"
if [ "${BITCOIN_STACK_CONFIG_LOCK_HELD:-0}" != 1 ]; then
  exec 8>"$state_dir/.config.lock"
  flock 8
fi
cd "$state_dir"

for tool in jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required; install it with your host package manager."
    exit 1
  }
done

# config.json is optional — default to an empty object so every field falls back.
config='{}'
[ -f "$config_file" ] && config=$(cat "$config_file")

get() { jq -r "$1 // \"${2:-}\"" <<<"$config"; }
flag() { jq -r "if $1 == true then 1 else 0 end" <<<"$config"; }

# Fresh installs generate separate passwords; upgrades reuse each existing value.
rpc_user=$(get '.bitcoin.node_username')
rpc_password=$(get '.bitcoin.node_password')
bitcoin_enabled=$(jq -r 'if ((.bitcoin // {}) | has("enabled")) then if .bitcoin.enabled == true then 1 else 0 end else empty end' <<<"$config")
monero_enabled=$(jq -r 'if ((.monero // {}) | has("enabled")) then if .monero.enabled == true then 1 else 0 end else empty end' <<<"$config")
monero_rpc_user=$(get '.monero.node_username')
monero_rpc_password=$(get '.monero.node_password')
monero_wallet_rpc_user=$(sed -n 's/^MONERO_WALLET_RPC_USER=//p' "$env_file" 2>/dev/null || true)
monero_wallet_rpc_password=$(sed -n 's/^MONERO_WALLET_RPC_PASSWORD=//p' "$env_file" 2>/dev/null || true)
monero_wallet_password=$(sed -n 's/^MONERO_WALLET_PASSWORD=//p' "$env_file" 2>/dev/null || true)
dashboard_password=$(get '.dashboard.password')
dashboard_password_set=$(jq -r 'if ((.dashboard // {}) | has("password")) then 1 else 0 end' <<<"$config")
had_env=0
[ -f "$env_file" ] && had_env=1
[ -n "$rpc_user" ] || rpc_user=$(sed -n 's/^BITCOIN_RPC_USER=//p' "$env_file" 2>/dev/null || true)
[ -n "$rpc_password" ] || rpc_password=$(sed -n 's/^BITCOIN_RPC_PASSWORD=//p' "$env_file" 2>/dev/null || true)
[ -n "$bitcoin_enabled" ] || bitcoin_enabled=$(sed -n 's/^BITCOIN_ENABLED=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_enabled" ] || monero_enabled=$(sed -n 's/^MONERO_ENABLED=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_rpc_user" ] || monero_rpc_user=$(sed -n 's/^MONERO_RPC_USER=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_rpc_password" ] || monero_rpc_password=$(sed -n 's/^MONERO_RPC_PASSWORD=//p' "$env_file" 2>/dev/null || true)
[ "$dashboard_password_set" = "1" ] || dashboard_password=$(sed -n 's/^DASHBOARD_PASSWORD=//p' "$env_file" 2>/dev/null || true)
[ -n "$bitcoin_enabled" ] || bitcoin_enabled=1
[ -n "$monero_enabled" ] || monero_enabled=0
[ -n "$rpc_user" ] || rpc_user="admin"
[ -n "$monero_rpc_user" ] || monero_rpc_user="admin"
[ -n "$monero_wallet_rpc_user" ] || monero_wallet_rpc_user="admin"
[ -n "$rpc_password" ] || rpc_password=$(openssl rand -hex 24)
[ -n "$monero_rpc_password" ] || monero_rpc_password=$(openssl rand -hex 24)
[ -n "$monero_wallet_rpc_password" ] || monero_wallet_rpc_password=$(openssl rand -hex 24)
[ -n "$monero_wallet_password" ] || monero_wallet_password=$(openssl rand -hex 24)
if [ "$had_env" = "0" ] && [ "$dashboard_password_set" = "0" ] && [ -z "$dashboard_password" ]; then
  dashboard_password=$(openssl rand -hex 24)
fi

data_dir=$(get '.bitcoin.data_dir')
if [ -z "$data_dir" ]; then
  if [ -n "${BITCOIN_STACK_DATA_DIR:-}" ]; then
    data_dir=$BITCOIN_STACK_DATA_DIR/bitcoin
  else
    data_dir=./data/bitcoin
  fi
fi
monero_data_dir=$(get '.monero.data_dir')
if [ -z "$monero_data_dir" ]; then
  if [ -n "${BITCOIN_STACK_DATA_DIR:-}" ]; then
    monero_data_dir=$BITCOIN_STACK_DATA_DIR/monero
  else
    monero_data_dir=./data/monero
  fi
fi
dbcache=$(jq -r '.bitcoin.dbcache_mb // empty' <<<"$config")
[ -n "$dbcache" ] || {
  dbcache=$(sed -n 's/^BITCOIN_DBCACHE=//p' "$env_file" 2>/dev/null || true)
  [ -n "$dbcache" ] || [ ! -f "$env_file" ] || dbcache=3000
}
[ -n "$dbcache" ] || dbcache=128
prune=$(jq -r '.bitcoin.prune_mb // empty' <<<"$config")
[ -n "$prune" ] || {
  prune=$(sed -n 's/^BITCOIN_PRUNE=//p' "$env_file" 2>/dev/null || true)
  [ -n "$prune" ] || [ ! -f "$env_file" ] || prune=0
}
[ -n "$prune" ] || prune=10000
mem_limit_mb=$(jq -r '.bitcoin.mem_limit_mb // 0' <<<"$config")
inbound_onion=$(jq -r 'if ((.bitcoin // {}) | has("inbound_onion")) then if .bitcoin.inbound_onion == true then 1 else 0 end else empty end' <<<"$config")
[ -n "$inbound_onion" ] || inbound_onion=$(sed -n 's/^BITCOIN_INBOUND_ONION=//p' "$env_file" 2>/dev/null || true)
[ -n "$inbound_onion" ] || inbound_onion=0
blockfilterindex=$(flag '.bitcoin.blockfilterindex')
rpc_expose=$(flag '.bitcoin.rpc_expose')
rpc_bind_ip=$(get '.bitcoin.rpc_bind_ip')
rpc_port=$(jq -r '.bitcoin.rpc_port // 8332' <<<"$config")
monero_rpc_expose=$(flag '.monero.rpc_expose')
monero_rpc_bind_ip=$(get '.monero.rpc_bind_ip')
monero_rpc_port=$(jq -r '.monero.rpc_port // 18081' <<<"$config")
monero_zmq_expose=$(flag '.monero.zmq_expose')
monero_zmq_bind_ip=$(get '.monero.zmq_bind_ip')
monero_zmq_port=$(jq -r '.monero.zmq_port // 18083' <<<"$config")
[ "$bitcoin_enabled" = "1" ] || rpc_expose=0
[ "$monero_enabled" = "1" ] || { monero_rpc_expose=0; monero_zmq_expose=0; }
bitcoin_resource_profile=$(get '.bitcoin.resource_profile')
monero_resource_profile=$(get '.monero.resource_profile')
[ -n "$bitcoin_resource_profile" ] || bitcoin_resource_profile=$(sed -n 's/^BITCOIN_RESOURCE_PROFILE=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_resource_profile" ] || monero_resource_profile=$(sed -n 's/^MONERO_RESOURCE_PROFILE=//p' "$env_file" 2>/dev/null || true)
[ -n "$bitcoin_resource_profile" ] || bitcoin_resource_profile=off
[ -n "$monero_resource_profile" ] || monero_resource_profile=off
bitcoin_steady_cpus=$(jq -r '.bitcoin.steady_cpus // empty' <<<"$config")
bitcoin_steady_mem_limit_mb=$(jq -r '.bitcoin.steady_mem_limit_mb // empty' <<<"$config")
monero_steady_cpus=$(jq -r '.monero.steady_cpus // empty' <<<"$config")
monero_steady_mem_limit_mb=$(jq -r '.monero.steady_mem_limit_mb // empty' <<<"$config")
[ -n "$bitcoin_steady_cpus" ] || bitcoin_steady_cpus=$(sed -n 's/^BITCOIN_STEADY_CPUS=//p' "$env_file" 2>/dev/null || true)
[ -n "$bitcoin_steady_mem_limit_mb" ] || bitcoin_steady_mem_limit_mb=$(sed -n 's/^BITCOIN_STEADY_MEM_LIMIT_MB=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_steady_cpus" ] || monero_steady_cpus=$(sed -n 's/^MONERO_STEADY_CPUS=//p' "$env_file" 2>/dev/null || true)
[ -n "$monero_steady_mem_limit_mb" ] || monero_steady_mem_limit_mb=$(sed -n 's/^MONERO_STEADY_MEM_LIMIT_MB=//p' "$env_file" 2>/dev/null || true)
[ -n "$bitcoin_steady_cpus" ] || bitcoin_steady_cpus=1
[ -n "$bitcoin_steady_mem_limit_mb" ] || bitcoin_steady_mem_limit_mb=2048
[ -n "$monero_steady_cpus" ] || monero_steady_cpus=1
[ -n "$monero_steady_mem_limit_mb" ] || monero_steady_mem_limit_mb=2048
dashboard_onion=$(jq -r 'if ((.dashboard // {}) | has("onion")) then if .dashboard.onion == true then 1 else 0 end else empty end' <<<"$config")
[ -n "$dashboard_onion" ] || dashboard_onion=$(sed -n 's/^DASHBOARD_ONION=//p' "$env_file" 2>/dev/null || true)
[ -n "$dashboard_onion" ] || dashboard_onion=0
dashboard_control=$(flag '.dashboard.control')
dashboard_bind_ip=$(get '.dashboard.bind_ip' '127.0.0.1')
telegram_bot_token=$(get '.notifications.telegram_bot_token')
telegram_chat_id=$(get '.notifications.telegram_chat_id')
healthchecks_url=$(get '.notifications.healthchecks_url')
alert_new_block=$(flag '.notifications.alert_new_block')
alert_new_block_monero=$(flag '.notifications.alert_new_block_monero')
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
watch_wallets_b64=$(jq -cej --argjson defaults "$default_wallets" '
  def public_key:
    type == "string" and
    (gsub("^\\s+|\\s+$"; "") |
      (test("^(?:(?:bc1|tb1|bcrt1)[0-9a-z]{20,}|[13][1-9A-HJ-NP-Za-km-z]{25,34}|[xtyuzv]pub[1-9A-HJ-NP-Za-km-z]{107})$") or
       (test("^(?:addr|pk|pkh|wpkh|sh|wsh|tr|rawtr|combo|raw|multi|sortedmulti)\\(") and
        (test("\\s") | not) and
        (test("(^|[^A-Za-z0-9])[xtyuzvXYZUV]prv[A-Za-z0-9]+|(^|[^1-9A-HJ-NP-Za-km-z])[5KL9c][1-9A-HJ-NP-Za-km-z]{50,51}($|[^1-9A-HJ-NP-Za-km-z])") | not))));
  (if has("wallets") then .wallets else $defaults end) |
  if type != "array" then error("wallets must be an array")
  elif all(.[]; type == "object" and (.key | public_key)) then .
  else error("wallets accept only public addresses, extended public keys, or public descriptors; remove private or invalid material from config.json") end
' <<<"$config" | base64 | tr -d '\n')

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
check_alnum "monero node_username" "$monero_rpc_user"
check_alnum "monero node_password" "$monero_rpc_password"
check_alnum "monero wallet RPC username" "$monero_wallet_rpc_user"
check_alnum "monero wallet RPC password" "$monero_wallet_rpc_password"
check_alnum "monero wallet password" "$monero_wallet_password"
check_alnum "dashboard password" "$dashboard_password"

if [ "$rpc_expose" = "1" ] && ((${#rpc_password} < 24)); then
  echo "bitcoin.node_password must be at least 24 characters when bitcoin.rpc_expose is true."
  exit 1
fi
if [ "$monero_rpc_expose" = "1" ] && ((${#monero_rpc_password} < 24)); then
  echo "monero.node_password must be at least 24 characters when monero.rpc_expose is true."
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
case "$rpc_port" in '' | 0* | *[!0-9]*)
  echo "bitcoin.rpc_port must be a whole number from 1 to 65535."
  exit 1
  ;;
esac
if ((${#rpc_port} > 5 || 10#$rpc_port > 65535)); then
  echo "bitcoin.rpc_port must be a whole number from 1 to 65535."
  exit 1
fi
if [ "$rpc_expose" = "1" ] && [ "$rpc_bind_ip" = "$dashboard_bind_ip" ] && [ "$rpc_port" = "80" ]; then
  echo "bitcoin.rpc_port conflicts with the dashboard on $rpc_bind_ip:80."
  exit 1
fi

validate_monero_port() {
  case "$2" in '' | 0* | *[!0-9]*)
    echo "$1 must be a whole number from 1 to 65535."
    exit 1
    ;;
  esac
  if ((${#2} > 5 || 10#$2 > 65535)); then
    echo "$1 must be a whole number from 1 to 65535."
    exit 1
  fi
}
validate_monero_port monero.rpc_port "$monero_rpc_port"
validate_monero_port monero.zmq_port "$monero_zmq_port"
case "$bitcoin_resource_profile" in compact | off) ;; *) echo "bitcoin.resource_profile must be compact or off."; exit 1 ;; esac
case "$monero_resource_profile" in compact | off) ;; *) echo "monero.resource_profile must be compact or off."; exit 1 ;; esac
validate_steady_limits() {
  local node=$1 cpus=$2 memory=$3
  if ! awk -v value="$cpus" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9][0-9]?)?$/ && value >= 0.01 && value <= 256) }'; then
    echo "$node.steady_cpus must be a number from 0.01 to 256 with at most two decimal places."
    exit 1
  fi
  case "$memory" in '' | *[!0-9]*)
    echo "$node.steady_mem_limit_mb must be a whole number from 257 to 1048576."
    exit 1
    ;;
  esac
  if [ "$memory" -le 256 ] || [ "$memory" -gt 1048576 ]; then
    echo "$node.steady_mem_limit_mb must be a whole number from 257 to 1048576."
    exit 1
  fi
}
for node in bitcoin monero; do
  if ! jq -e --arg node "$node" '
    (.[$node] // {}) as $settings |
    (($settings | has("steady_cpus") | not) or ($settings.steady_cpus | type == "number")) and
    (($settings | has("steady_mem_limit_mb") | not) or
      ($settings.steady_mem_limit_mb | type == "number" and floor == .))
  ' >/dev/null <<<"$config"; then
    echo "$node steady resource limits must be JSON numbers."
    exit 1
  fi
done
validate_steady_limits bitcoin "$bitcoin_steady_cpus" "$bitcoin_steady_mem_limit_mb"
validate_steady_limits monero "$monero_steady_cpus" "$monero_steady_mem_limit_mb"
if [ "$monero_rpc_expose" = "1" ]; then
  [ -n "$monero_rpc_bind_ip" ] || { echo "monero.rpc_bind_ip is required when monero.rpc_expose is true."; exit 1; }
  check_bind_ip monero.rpc_bind_ip "$monero_rpc_bind_ip" 0
fi
if [ "$monero_zmq_expose" = "1" ]; then
  [ -n "$monero_zmq_bind_ip" ] || { echo "monero.zmq_bind_ip is required when monero.zmq_expose is true."; exit 1; }
  check_bind_ip monero.zmq_bind_ip "$monero_zmq_bind_ip" 0
fi
if [ "$monero_rpc_expose" = "1" ] && [ "$monero_rpc_bind_ip" = "$dashboard_bind_ip" ] && [ "$monero_rpc_port" = "80" ]; then
  echo "monero.rpc_port conflicts with the dashboard on $monero_rpc_bind_ip:80."
  exit 1
fi
if [ "$monero_zmq_expose" = "1" ] && [ "$monero_zmq_bind_ip" = "$dashboard_bind_ip" ] && [ "$monero_zmq_port" = "80" ]; then
  echo "monero.zmq_port conflicts with the dashboard on $monero_zmq_bind_ip:80."
  exit 1
fi
if [ "$monero_rpc_expose" = "1" ] && [ "$monero_zmq_expose" = "1" ] && [ "$monero_rpc_bind_ip:$monero_rpc_port" = "$monero_zmq_bind_ip:$monero_zmq_port" ]; then
  echo "monero.rpc_port and monero.zmq_port conflict on $monero_rpc_bind_ip:$monero_rpc_port."
  exit 1
fi
if [ "$rpc_expose" = "1" ] && [ "$monero_rpc_expose" = "1" ] && [ "$rpc_bind_ip:$rpc_port" = "$monero_rpc_bind_ip:$monero_rpc_port" ]; then
  echo "bitcoin.rpc_port and monero.rpc_port conflict on $rpc_bind_ip:$rpc_port."
  exit 1
fi
if [ "$rpc_expose" = "1" ] && [ "$monero_zmq_expose" = "1" ] && [ "$rpc_bind_ip:$rpc_port" = "$monero_zmq_bind_ip:$monero_zmq_port" ]; then
  echo "bitcoin.rpc_port and monero.zmq_port conflict on $rpc_bind_ip:$rpc_port."
  exit 1
fi

compose_file=docker-compose.yml
[ "$rpc_expose" = "1" ] && compose_file=docker-compose.yml:docker-compose.rpc.yml
[ "$monero_rpc_expose" = "1" ] && compose_file=$compose_file:docker-compose.monero-rpc.yml
[ "$monero_zmq_expose" = "1" ] && compose_file=$compose_file:docker-compose.monero-zmq.yml
compose_profiles=
[ "$bitcoin_enabled" = "1" ] && compose_profiles=bitcoin
if [ "$monero_enabled" = "1" ]; then
  [ -z "$compose_profiles" ] || compose_profiles=$compose_profiles,
  compose_profiles=${compose_profiles}monero
fi

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

if [ "${BITCOIN_STACK_VALIDATE_ONLY:-0}" = 1 ]; then
  exit 0
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

env_tmp=$(mktemp "$state_dir/.env.tmp.XXXXXX")
trap 'rm -f "$env_tmp"' EXIT
cat >"$env_tmp" <<EOF
COMPOSE_FILE=$compose_file
COMPOSE_PROFILES=$compose_profiles
BITCOIN_ENABLED=$bitcoin_enabled
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
BITCOIN_RESOURCE_PROFILE=$bitcoin_resource_profile
BITCOIN_STEADY_CPUS=$bitcoin_steady_cpus
BITCOIN_STEADY_MEM_LIMIT_MB=$bitcoin_steady_mem_limit_mb
MONERO_ENABLED=$monero_enabled
MONERO_RPC_URL=http://172.29.0.30:18085
MONERO_RPC_USER=$monero_rpc_user
MONERO_RPC_PASSWORD=$monero_rpc_password
MONERO_WALLET_RPC_URL=http://172.29.0.31:18082
MONERO_WALLET_RPC_USER=$monero_wallet_rpc_user
MONERO_WALLET_RPC_PASSWORD=$monero_wallet_rpc_password
MONERO_WALLET_PASSWORD=$monero_wallet_password
MONERO_DATA_DIR=$monero_data_dir
MONERO_RPC_EXPOSE=$monero_rpc_expose
MONERO_RPC_BIND_IP=$monero_rpc_bind_ip
MONERO_RPC_PORT=$monero_rpc_port
MONERO_ZMQ_EXPOSE=$monero_zmq_expose
MONERO_ZMQ_BIND_IP=$monero_zmq_bind_ip
MONERO_ZMQ_PORT=$monero_zmq_port
MONERO_RESOURCE_PROFILE=$monero_resource_profile
MONERO_STEADY_CPUS=$monero_steady_cpus
MONERO_STEADY_MEM_LIMIT_MB=$monero_steady_mem_limit_mb
DASHBOARD_PASSWORD=$dashboard_password
DASHBOARD_ONION=$dashboard_onion
DASHBOARD_CONTROL=$dashboard_control
DASHBOARD_BIND_IP=$dashboard_bind_ip
TELEGRAM_BOT_TOKEN=$telegram_bot_token
TELEGRAM_CHAT_ID=$telegram_chat_id
HEALTHCHECKS_URL=$healthchecks_url
ALERT_NEW_BLOCK=$alert_new_block
ALERT_NEW_BLOCK_MONERO=$alert_new_block_monero
NODE_NAME=$(hostname)
STACK_VERSION=$stack_version
STACK_ROOT=$stack_root
WATCH_WALLETS_B64=$watch_wallets_b64
EOF
chmod 600 "$env_tmp"
mv -f "$env_tmp" "$env_file"

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"
mkdir -p "$monero_data_dir"
if [ "$package_managed" = "1" ] && [ "$data_dir" = "${BITCOIN_STACK_DATA_DIR%/}/bitcoin" ]; then
  chown 1000:1000 "$data_dir"
  chmod 700 "$data_dir"
fi
if [ "$package_managed" = "1" ] && [ "$monero_data_dir" = "${BITCOIN_STACK_DATA_DIR%/}/monero" ]; then
  chown 1000:1000 "$monero_data_dir"
  chmod 700 "$monero_data_dir"
fi

echo "Done. Start local images with: $stack_command up (download missing images: $stack_command pull)."
