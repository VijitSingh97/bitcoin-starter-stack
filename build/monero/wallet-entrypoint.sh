#!/bin/sh
set -eu

: "${MONERO_RPC_USER:?missing MONERO_RPC_USER}"
: "${MONERO_RPC_PASSWORD:?missing MONERO_RPC_PASSWORD}"
: "${MONERO_WALLET_RPC_USER:?missing MONERO_WALLET_RPC_USER}"
: "${MONERO_WALLET_RPC_PASSWORD:?missing MONERO_WALLET_RPC_PASSWORD}"

umask 077
config=/run/monero-wallet/wallet-rpc.conf
cat >"$config" <<EOF
wallet-dir=/wallets
daemon-address=http://172.29.0.30:18085
daemon-login=$MONERO_RPC_USER:$MONERO_RPC_PASSWORD
trusted-daemon=1
rpc-bind-ip=0.0.0.0
rpc-bind-port=18082
confirm-external-bind=1
rpc-login=$MONERO_WALLET_RPC_USER:$MONERO_WALLET_RPC_PASSWORD
disable-rpc-ban=1
log-file=/run/monero-wallet/wallet-rpc.log
log-level=0
max-log-file-size=1048576
max-log-files=1
EOF

exec monero-wallet-rpc --non-interactive --config-file="$config"
