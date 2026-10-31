#!/bin/sh
bitcoin-cli -datadir=/data -conf=/tmp/bitcoin.conf getblockchaininfo >/dev/null
