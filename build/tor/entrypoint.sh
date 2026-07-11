#!/bin/sh
# Render the runtime torrc — the unprivileged tor user can't write /etc/tor,
# so the effective config goes to /tmp, regenerated each start. The dashboard
# hidden service is opt-in (dashboard.onion in config.json) and appended only
# when enabled, so the default stack publishes nothing.
set -eu

cat /etc/tor/torrc >/tmp/torrc

if [ "${DASHBOARD_ONION:-0}" = "1" ]; then
  cat >>/tmp/torrc <<EOF

# Dashboard hidden service (dashboard.onion in config.json)
HiddenServiceDir /var/lib/tor/dashboard_onion/
HiddenServicePort 80 172.29.0.27:8000
EOF
fi

exec tor -f /tmp/torrc
