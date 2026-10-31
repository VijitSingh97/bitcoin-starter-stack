#!/bin/sh
# Render the runtime torrc — the unprivileged tor user can't write /etc/tor,
# so the effective config goes to /tmp, regenerated each start. The dashboard
# hidden service is appended only when dashboard.onion is enabled.
set -eu

cat /etc/tor/torrc >/tmp/torrc

if [ "${DASHBOARD_ONION:-0}" = "1" ]; then
  cat >>/tmp/torrc <<EOF

# Dashboard hidden service (dashboard.onion in config.json)
HiddenServiceDir /var/lib/tor/dashboard_onion/
HiddenServicePort 80 172.29.0.27:8001
EOF
fi

tor -f /tmp/torrc &
tor_pid=$!
socat TCP4-LISTEN:8000,reuseaddr,fork,max-children=32 TCP4:172.29.0.27:8000 &
socat_pid=$!
rpc_pid=
if [ "${BITCOIN_RPC_EXPOSE:-0}" = "1" ]; then
  socat TCP4-LISTEN:8332,reuseaddr,fork,max-children=32 TCP4:172.29.0.26:8332 &
  rpc_pid=$!
fi
monero_rpc_pid=
if [ "${MONERO_RPC_EXPOSE:-0}" = "1" ]; then
  socat TCP4-LISTEN:18081,reuseaddr,fork,max-children=32 TCP4:172.29.0.30:18081 &
  monero_rpc_pid=$!
fi
monero_zmq_pid=
if [ "${MONERO_ZMQ_EXPOSE:-0}" = "1" ]; then
  socat TCP4-LISTEN:18083,reuseaddr,fork,max-children=32 TCP4:172.29.0.30:18083 &
  monero_zmq_pid=$!
fi
tari_grpc_pid=
if [ "${TARI_GRPC_EXPOSE:-0}" = "1" ]; then socat TCP4-LISTEN:18142,reuseaddr,fork,max-children=32 TCP4:172.29.0.32:18142 & tari_grpc_pid=$!; fi
litecoin_rpc_pid=
if [ "${LITECOIN_RPC_EXPOSE:-0}" = "1" ]; then socat TCP4-LISTEN:9332,reuseaddr,fork,max-children=32 TCP4:172.29.0.33:9332 & litecoin_rpc_pid=$!; fi
dogecoin_rpc_pid=
if [ "${DOGECOIN_RPC_EXPOSE:-0}" = "1" ]; then socat TCP4-LISTEN:22555,reuseaddr,fork,max-children=32 TCP4:172.29.0.34:22555 & dogecoin_rpc_pid=$!; fi
bitcoincash_rpc_pid=
if [ "${BITCOINCASH_RPC_EXPOSE:-0}" = "1" ]; then socat TCP4-LISTEN:18332,reuseaddr,fork,max-children=32 TCP4:172.29.0.35:8332 & bitcoincash_rpc_pid=$!; fi
zcash_rpc_pid=
if [ "${ZCASH_RPC_EXPOSE:-0}" = "1" ]; then socat TCP4-LISTEN:18232,reuseaddr,fork,max-children=32 TCP4:172.29.0.27:18232 & zcash_rpc_pid=$!; fi
zcash_seed_1_pid=''
zcash_seed_2_pid=''
zcash_seed_3_pid=''
zcash_seed_4_pid=''
if [ "${ZCASH_ENABLED:-0}" = "1" ] && [ "${ZCASH_ACTIVE:-1}" = "1" ]; then
  socat TCP4-LISTEN:18233,reuseaddr,fork,max-children=8 SOCKS4A:127.0.0.1:dnsseed.str4d.xyz:8233,socksport=9050 & zcash_seed_1_pid=$!
  socat TCP4-LISTEN:18234,reuseaddr,fork,max-children=8 SOCKS4A:127.0.0.1:dnsseed.z.cash:8233,socksport=9050 & zcash_seed_2_pid=$!
  socat TCP4-LISTEN:18235,reuseaddr,fork,max-children=8 SOCKS4A:127.0.0.1:mainnet.seeder.shieldedinfra.net:8233,socksport=9050 & zcash_seed_3_pid=$!
  socat TCP4-LISTEN:18236,reuseaddr,fork,max-children=8 SOCKS4A:127.0.0.1:mainnet.seeder.zfnd.org:8233,socksport=9050 & zcash_seed_4_pid=$!
fi
pids="$tor_pid $socat_pid ${rpc_pid:-} ${monero_rpc_pid:-} ${monero_zmq_pid:-} ${tari_grpc_pid:-} ${litecoin_rpc_pid:-} ${dogecoin_rpc_pid:-} ${bitcoincash_rpc_pid:-} ${zcash_rpc_pid:-} $zcash_seed_1_pid $zcash_seed_2_pid $zcash_seed_3_pid $zcash_seed_4_pid"

stop() {
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
}
trap 'stop; exit 0' TERM INT

status=0
while :; do
  running=1
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || running=0
  done
  [ "$running" = "1" ] || break
  sleep 1
done
for pid in $pids; do
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || status=$?
    break
  fi
done
stop
exit "$status"
