#!/bin/sh
set -eu
cookie_file="${ZCASH_COOKIE_FILE:-/data/.cookie}"
cookie_owner_uid="${ZCASH_COOKIE_OWNER_UID:-10001}"
dashboard_gid="${ZCASH_DASHBOARD_GID:-1000}"
[ -f "$cookie_file" ] && [ ! -L "$cookie_file" ] || exit 1
if [ "$(id -u)" = 0 ] && [ "${1:-}" != cookie-owner ]; then
  chown "$cookie_owner_uid:$dashboard_gid" "$cookie_file"
  exec setpriv --reuid="$cookie_owner_uid" --regid="$dashboard_gid" --clear-groups "$0" cookie-owner
fi
[ "$(id -u)" = "$cookie_owner_uid" ] || exit 1
cookie="$(cat "$cookie_file")"
case "$cookie" in
  __cookie__:*:*) exit 1 ;;
  __cookie__:*) [ "${#cookie}" -eq 55 ] || exit 1 ;;
  *) exit 1 ;;
esac
chmod 0640 "$cookie_file"
response="$(curl -fsS --max-time 10 \
  --user "$cookie" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":"health","method":"getblockchaininfo","params":[]}' \
  http://127.0.0.1:8232/)"
printf '%s' "$response" | grep -q '"result":{'
