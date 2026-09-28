#!/usr/bin/env bash
# disable-bt-status-vhost.sh - BT ships phpfpm_status.conf, whose `allow 127.0.0.1;
# deny all;` did NOT hold: from the internet with `Host: 127.0.0.1` the nginx
# stub_status endpoint answered 200. No PHP is installed on this box, so the vhost
# is dead weight - take it out of the include path.
set -uo pipefail

VDIR=/www/server/panel/vhost/nginx
F="$VDIR/phpfpm_status.conf"

echo '########## BEFORE ##########'
[ -f "$F" ] && echo "  present: $F" || echo '  (already absent)'
echo "  external probe /nginx_status with Host: 127.0.0.1 -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: 127.0.0.1' http://127.0.0.1/nginx_status)"

echo
echo '########## DISABLE ##########'
if [ -f "$F" ]; then
    mv "$F" "$F.disabled-by-agent"
    echo "  renamed to $F.disabled-by-agent (BT may recreate it on panel update - re-run this)"
else
    echo '  nothing to do'
fi

echo
echo '########## RELOAD ##########'
if /www/server/nginx/sbin/nginx -t 2>&1 | sed 's/^/  /'; then
    /www/server/nginx/sbin/nginx -s reload 2>&1 | sed 's/^/  /' || /etc/init.d/nginx reload 2>&1 | sed 's/^/  /'
    echo '  reloaded'
else
    echo 'FATAL: config broken, restoring' >&2
    mv "$F.disabled-by-agent" "$F"
    /www/server/nginx/sbin/nginx -s reload
    exit 1
fi
sleep 2

echo
echo '########## AFTER ##########'
echo "  local status endpoint  -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H 'Host: 127.0.0.1' http://127.0.0.1/nginx_status)  (401/404 = closed)"
echo "  tavern by IP           -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1/)  (by 127.0.0.1 Host it may differ; external is what counts)"
echo "  vhosts loaded:"
ls -1 "$VDIR"/*.conf | sed 's/^/    /'

echo
echo 'disable-bt-status-vhost complete'
