#!/bin/sh
set -eu
umask 077
cat >/tmp/bitcoin.conf <<EOF
server=1
disablewallet=1
rpcbind=0.0.0.0
rpcallowip=172.29.0.0/24
rpcuser=$BITCOINCASH_RPC_USER
rpcpassword=$BITCOINCASH_RPC_PASSWORD
prune=$BITCOINCASH_PRUNE
proxy=$TOR_PROXY
onion=$TOR_PROXY
onlynet=onion
listen=0
dnsseed=0
discover=0
EOF
exec bitcoind -datadir=/data -conf=/tmp/bitcoin.conf
