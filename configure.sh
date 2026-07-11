#!/usr/bin/env bash
# Render config.json into a gitignored .env for docker compose,
# and create the data directory. Run once before `docker compose up`.
set -euo pipefail
cd "$(dirname "$0")"

for tool in jq openssl; do
  command -v "$tool" >/dev/null || {
    echo "$tool is required: sudo apt install $tool"
    exit 1
  }
done

if [ ! -f config.json ]; then
  echo "No config.json. Create yours with: cp config.example.json config.json"
  exit 1
fi

if grep -q "create_a_" config.json; then
  echo "Edit config.json first: set your own node username and password."
  exit 1
fi

rpc_user=$(jq -r '.bitcoin.node_username // empty' config.json)
rpc_password=$(jq -r '.bitcoin.node_password // empty' config.json)
data_dir=$(jq -r '.bitcoin.data_dir // "./data/bitcoin"' config.json)
dbcache=$(jq -r '.bitcoin.dbcache_mb // 3000' config.json)
prune=$(jq -r '.bitcoin.prune_mb // 0' config.json)
inbound_onion=$(jq -r 'if .bitcoin.inbound_onion == true then 1 else 0 end' config.json)
dashboard_password=$(jq -r '.dashboard.password // empty' config.json)

if [ -z "$rpc_user" ] || [ -z "$rpc_password" ]; then
  echo "config.json is missing bitcoin.node_username or bitcoin.node_password."
  exit 1
fi

case "$rpc_user$rpc_password$dashboard_password" in
  *[!a-zA-Z0-9]*)
    echo "Use only letters and numbers in node_username, node_password, and dashboard password."
    exit 1
    ;;
esac

# bitcoind rejects prune targets between 1 and 549 MB
case "$prune" in *[!0-9]*) prune=-1 ;; esac
if [ "$prune" -lt 0 ] || { [ "$prune" -ne 0 ] && [ "$prune" -lt 550 ]; }; then
  echo "prune_mb must be 0 (full node) or at least 550."
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
DASHBOARD_PASSWORD=$dashboard_password
EOF
chmod 600 .env

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"

echo "Done. Start the stack with: docker compose up -d"
