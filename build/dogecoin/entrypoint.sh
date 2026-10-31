#!/bin/sh
set -eu
umask 077
cat >/tmp/dogecoin.conf <<EOF
server=1
disablewallet=1
rpcbind=0.0.0.0
rpcallowip=172.29.0.0/24
rpcuser=$DOGECOIN_RPC_USER
rpcpassword=$DOGECOIN_RPC_PASSWORD
prune=$DOGECOIN_PRUNE
proxy=$TOR_PROXY
onion=$TOR_PROXY
onlynet=onion
listen=0
dnsseed=0
discover=0
EOF
exec dogecoind -datadir=/data -conf=/tmp/dogecoin.conf
