#!/bin/sh
set -eu

printf 'user = "%s:%s"\ndigest\nheader = "Content-Type: application/json"\ndata = "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":\\"healthcheck\\",\\"method\\":\\"get_info\\"}"\n' "$MONERO_RPC_USER" "$MONERO_RPC_PASSWORD" |
  curl --silent --show-error --fail --config - --max-time 10 http://127.0.0.1:18085/json_rpc |
  grep -q '"result"'
