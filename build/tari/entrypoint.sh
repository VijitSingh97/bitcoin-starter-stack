#!/bin/sh
set -eu
sed "s/__PRUNING_HORIZON__/$TARI_PRUNING_HORIZON/" /var/tari/config/config.toml >/var/tari/node/runtime-config.toml
export TARI_CONFIG=/var/tari/node/runtime-config.toml
exec start_tari_app.sh --disable-splash-screen --non-interactive-mode
