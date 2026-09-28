#!/usr/bin/env bash
# st-set-basicauth.sh - turn SillyTavern's HTTP basic auth on or off.
#
# The credentials are the ones already in config.yaml (basicAuthUser); this only
# flips the switch. The password is never printed and never leaves the host - the
# verification below reads it inside the shell.
#
# Usage: st-set-basicauth.sh [on|off]
#
# Rollback: config.yaml.pre-auth-<stamp> holds the previous file; flip back with
#           `st-set-basicauth.sh off`.

set -uo pipefail

WANT="${1:-on}"
CFG=/opt/sillytavern/config/config.yaml
ROOT=/opt/sillytavern

case "$WANT" in
    on)  VAL=true ;;
    off) VAL=false ;;
    *)   echo "FATAL: expected 'on' or 'off', got '$WANT'" >&2; exit 1 ;;
esac

[ -f "$CFG" ] || { echo "FATAL: $CFG not found" >&2; exit 1; }

echo '########## BEFORE ##########'
grep -nE '^basicAuthMode:' "$CFG" | sed 's/^/  /'

echo
echo '########## SET basicAuthMode: '"$VAL"' ##########'
cp -a "$CFG" "$CFG.pre-auth-$(date +%Y%m%d-%H%M%S)"
python3 - "$CFG" "$VAL" <<'PY'
import re, sys
path, value = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
new = re.sub(r'(?m)^basicAuthMode:.*$', f'basicAuthMode: {value}', text, count=1)
if new == text:
    raise SystemExit('FATAL: no basicAuthMode line found')
open(path, 'w', encoding='utf-8').write(new)
print('  ->', re.search(r'(?m)^basicAuthMode:.*$', new).group(0))
PY

echo
echo '########## RESTART ##########'
cd "$ROOT" && docker compose restart sillytavern 2>&1 | tail -2 | sed 's/^/  /'
sleep 20

echo
echo '########## VERIFY (credentials read on-host, never echoed) ##########'
UN=$(grep -A2 '^basicAuthUser:' "$CFG" | grep -m1 'username:' | sed 's/.*username: *//; s/"//g')
PW=$(grep -A2 '^basicAuthUser:' "$CFG" | grep -m1 'password:' | sed 's/.*password: *//; s/"//g')

echo "  container      : $(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' sillytavern)"
echo "  no credentials : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8000/)   $([ "$VAL" = true ] && echo '(401 expected)' || echo '(200 expected)')"
echo "  with creds     : $(curl -s -u "$UN:$PW" -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8000/)   (200 expected)"
echo "  title          : $(curl -s -u "$UN:$PW" --max-time 10 http://127.0.0.1:8000/ | grep -oE '<title>[^<]*</title>' | head -1)"
echo "  username       : ${UN:0:2}*** (masked; the full one is in config.yaml)"

echo
echo 'st-set-basicauth complete'
