#!/usr/bin/env bash
# Render config.json into a gitignored .env for docker compose,
# and create the data directory. Run once before `docker compose up`.
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || {
  echo "jq is required: sudo apt install jq"
  exit 1
}

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

if [ -z "$rpc_user" ] || [ -z "$rpc_password" ]; then
  echo "config.json is missing bitcoin.node_username or bitcoin.node_password."
  exit 1
fi

case "$rpc_user$rpc_password" in
  *[!a-zA-Z0-9]*)
    echo "Use only letters and numbers in node_username and node_password."
    exit 1
    ;;
esac

cat >.env <<EOF
BITCOIN_RPC_USER=$rpc_user
BITCOIN_RPC_PASSWORD=$rpc_password
BITCOIN_DATA_DIR=$data_dir
BITCOIN_DBCACHE=$dbcache
EOF
chmod 600 .env

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p "$data_dir"

echo "Done. Start the stack with: docker compose up -d"
