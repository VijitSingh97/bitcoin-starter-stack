#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || {
  echo "jq is required: sudo apt install jq"
  exit 1
}

if grep -q "create_a_" config.json; then
  echo "Edit config.json first: set your own node username and password."
  exit 1
fi

# Render .env for docker compose from config.json
cat >.env <<EOF
BITCOIN_RPC_USER=$(jq -r .bitcoin.node_username config.json)
BITCOIN_RPC_PASSWORD=$(jq -r .bitcoin.node_password config.json)
EOF
chmod 600 .env

# Create the data dir up front, or docker creates it root-owned
# and bitcoind (uid 1000) can't write to it
mkdir -p data/bitcoin

echo "Done. Start the stack with: docker compose up -d"
