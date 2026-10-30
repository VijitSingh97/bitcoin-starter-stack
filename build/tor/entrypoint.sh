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

stop() {
  kill "$tor_pid" "$socat_pid" ${rpc_pid:+"$rpc_pid"} 2>/dev/null || true
  wait "$tor_pid" "$socat_pid" ${rpc_pid:+"$rpc_pid"} 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT

status=0
while kill -0 "$tor_pid" 2>/dev/null && kill -0 "$socat_pid" 2>/dev/null && { [ -z "$rpc_pid" ] || kill -0 "$rpc_pid" 2>/dev/null; }; do
  sleep 1
done
if ! kill -0 "$tor_pid" 2>/dev/null; then
  wait "$tor_pid" || status=$?
elif ! kill -0 "$socat_pid" 2>/dev/null; then
  wait "$socat_pid" || status=$?
else
  wait "$rpc_pid" || status=$?
fi
stop
exit "$status"
