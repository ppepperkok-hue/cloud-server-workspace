#!/usr/bin/env bash
# harden-bt-panel.sh - enable BT panel HTTPS (SHA-256 self-signed) and set the panel IP allowlist.
#
# Idempotent: safe to re-run. Regenerates the cert only when missing (set FORCE_SSL=1 to force).
#
# Usage:  bash harden-bt-panel.sh <allowed-ip[,allowed-ip...]|none> <host-address>
#         BT_PANEL_HOST=<host-address> bash harden-bt-panel.sh <allowed-ip[,allowed-ip...]|none>
#
#   host-address  Where the panel is reached: an IPv4/IPv6 address or a DNS name. It is
#                 put into the self-signed certificate's subjectAltName. This repo is
#                 public, so no real address is stored here and the value has to be
#                 supplied at run time. Missing or malformed values abort the script
#                 before anything on the host is written.
#
# Why not BT's own "enable panel SSL": class/config.py CreateSSL() signs the self-signed
# cert with md5 (cert.sign(key, 'md5')), which modern browsers and OpenSSL 3 reject.
#
# Why limitip.conf: class/public.py check_ip_panel() treats it as an ALLOWLIST - empty or
# absent means "no restriction", non-empty means only the listed IPs (plus 127.0.0.1) may
# reach the panel. Separator is "," and ranges are written as "a.b.c.d-a.b.c.e"; CIDR is
# NOT supported. Recovery if you lock yourself out: run `bt 13` (removes the allowlist).
#
# Rollback: restore the tarballs under /root/backups/bt-panel-harden-* then `/etc/init.d/bt restart`.

set -uo pipefail

P=/www/server/panel
ALLOW="${1:-}"
HOST="${2:-${BT_PANEL_HOST:-}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/root/backups/bt-panel-harden-${STAMP}"

die() {
    echo "FATAL: $*" >&2
    exit 1
}

usage() {
    printf '%s\n' "Usage: bash harden-bt-panel.sh <allowed-ip[,ip...]|none> <host-address>

  allowed-ip    Panel allowlist: one IP, a comma-separated list, an
                a.b.c.d-a.b.c.e range, or none to clear the allowlist.
                CIDR is not supported by the panel.
  host-address  Where the panel is reached: IPv4, IPv6 or a DNS name.
                Written into the self-signed certificate's subjectAltName.
                No default: this repo is public, so the real value is not
                stored here. BT_PANEL_HOST is read when the second argument
                is omitted.

  FORCE_SSL=1   regenerate the certificate even if one is already present.

A missing or malformed host address aborts before anything is written to
the host (no backup dir, no certificate, no panel restart)."
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac

if [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi

if [ -z "$ALLOW" ]; then
    usage >&2
    exit 2
fi

if [ -z "$HOST" ]; then
    echo "FATAL: no host address given. Pass where the panel is reached (IPv4/IPv6/DNS name), e.g.:
    bash $0 ${ALLOW} 203.0.113.10
  or set BT_PANEL_HOST=203.0.113.10 (see --help)" >&2
    exit 2
fi

case "$HOST" in
    '<'*'>')
        die "host address '$HOST' is a redaction placeholder, not a real value.
  Supply the address the panel is reached at (public IP, private IP or DNS name)."
        ;;
esac

# Accept IPv4 / IPv6 / DNS names. A stray value must never reach the openssl
# subjectAltName as a bogus IP:, nor the shell as a redirection.
is_ipv4() {
    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ $1 =~ ^${octet}(\.${octet}){3}$ ]]
}

is_ipv6() {
    local addr=$1 group n=0
    [[ $addr == *:* ]] || return 1
    [[ $addr =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ $addr == *:::* || $addr == *::*::* ]] && return 1
    [[ $addr == *: && $addr != *:: ]] && return 1
    [[ $addr == :* && $addr != ::* ]] && return 1
    for group in ${addr//:/ }; do
        [ "${#group}" -le 4 ] || return 1
        n=$((n + 1))
    done
    if [[ $addr == *::* ]]; then
        [ "$n" -le 7 ]
    else
        [ "$n" -eq 8 ]
    fi
}

is_dns_name() {
    local name=$1 label
    [ "${#name}" -le 253 ] || return 1
    [[ $name =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ $name == .* || $name == *. || $name == *..* ]] && return 1
    for label in ${name//./ }; do
        [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

# --- OpenSSL capability probe -------------------------------------------------
# "openssl x509 -checkip/-checkhost" only exist since OpenSSL 3.4, but the target
# host runs an older 3.x, where the same question is answered by
# "openssl verify -verify_ip/-verify_hostname" (available since 1.0.2/1.1.0).
# Probe once and pick the path this host actually supports - guessing wrong
# would make every run fail with a bogus "cert lacks the SAN" complaint.
X509_CHECK_IP=0
X509_CHECK_HOST=0
X509_HELP="$(openssl x509 -help 2>&1 || true)"
case "$X509_HELP" in
    *-checkip*) X509_CHECK_IP=1 ;;
esac
case "$X509_HELP" in
    *-checkhost*) X509_CHECK_HOST=1 ;;
esac
unset X509_HELP

# The fallback needs "openssl verify -verify_ip/-verify_hostname" (since 1.0.2)
# plus the two options that keep the self-signed cert usable as its own anchor.
# -partial_chain (1.0.2+) and -no-CApath (1.1.0+) are probed separately: an
# unknown option makes openssl exit 1, which would be reported as a SAN
# mismatch instead of "this host cannot do the check at all".
VERIFY_CHECK_IP=0
VERIFY_CHECK_HOST=0
VERIFY_OPT_CHAIN=0
VERIFY_OPT_NOCAPATH=0
VERIFY_HELP="$(openssl verify -help 2>&1 || true)"
case "$VERIFY_HELP" in
    *-verify_ip*) VERIFY_CHECK_IP=1 ;;
esac
case "$VERIFY_HELP" in
    *-verify_hostname*) VERIFY_CHECK_HOST=1 ;;
esac
case "$VERIFY_HELP" in
    *-partial_chain*) VERIFY_OPT_CHAIN=1 ;;
esac
case "$VERIFY_HELP" in
    *-no-CApath*) VERIFY_OPT_NOCAPATH=1 ;;
esac
unset VERIFY_HELP

# Print the certificate's subjectAltName. "x509 -ext" arrived in OpenSSL 1.1.1,
# so fall back to the human-readable "-text" dump on older builds - otherwise the
# SAN silently vanishes from the report and the placeholder warning never fires.
cert_san_text() {
    local cert=$1 out
    out="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ')"
    case "$out" in
        *'IP Address:'* | *'DNS:'*)
            printf '%s\n' "$out"
            return 0
            ;;
    esac
    out="$(openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')"
    printf '%s\n' "$out"
}

# SAN_CHECK_STATUS: 0 = the certificate carries $HOST, 1 = it does not,
# 2 = this host's OpenSSL cannot answer the question at all.
SAN_CHECK_STATUS=1
SAN_CHECK_DETAIL=""

is_live_host() {
    # True when $1 (a cert path) matches the validated $HOST, per OpenSSL itself.
    # -checkip canonicalises IPv6 (2001:db8::10 -> 2001:DB8:0:0:0:0:0:10), so a plain
    # string compare against the SAN text would reject a perfectly good certificate.
    #
    # "openssl x509 -checkip" answers with exit code 1 for BOTH a mismatch and a
    # broken/unreadable certificate, so the message decides which one it was.
    # Reading only the exit code would blame the SAN for a tool failure.
    local cert=$1 rc opt out
    SAN_CHECK_STATUS=1
    SAN_CHECK_DETAIL=""
    if [ "$SAN_TYPE" = IP ] && [ "$X509_CHECK_IP" = 1 ]; then
        out="$(openssl x509 -in "$cert" -noout -checkip "$HOST" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            SAN_CHECK_STATUS=0
        elif printf '%s' "$out" | grep -q 'does NOT match'; then
            SAN_CHECK_STATUS=1
        else
            SAN_CHECK_STATUS=2
        fi
    elif [ "$SAN_TYPE" = DNS ] && [ "$X509_CHECK_HOST" = 1 ]; then
        out="$(openssl x509 -in "$cert" -noout -checkhost "$HOST" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            SAN_CHECK_STATUS=0
        elif printf '%s' "$out" | grep -q 'does NOT match'; then
            SAN_CHECK_STATUS=1
        else
            SAN_CHECK_STATUS=2
        fi
    else
        # Fallback for OpenSSL < 3.4: verify the certificate against itself as the
        # trust anchor and ask for the host name / address to be matched.
        # A verification failure exits 2 ("...mismatch"), a broken tool exits 1.
        opt=verify_hostname
        [ "$SAN_TYPE" = IP ] && opt=verify_ip
        if [ "$SAN_TYPE" = IP ] && [ "$VERIFY_CHECK_IP" != 1 ]; then
            SAN_CHECK_STATUS=2
            SAN_CHECK_DETAIL="this openssl has no 'verify -verify_ip'"
            return 1
        fi
        if [ "$SAN_TYPE" = DNS ] && [ "$VERIFY_CHECK_HOST" != 1 ]; then
            SAN_CHECK_STATUS=2
            SAN_CHECK_DETAIL="this openssl has no 'verify -verify_hostname'"
            return 1
        fi
        verify_opts="-partial_chain -no-CApath"
        [ "$VERIFY_OPT_CHAIN" = 1 ] || verify_opts="-no-CApath"
        [ "$VERIFY_OPT_NOCAPATH" = 1 ] || verify_opts="${verify_opts#-no-CApath }"
        # shellcheck disable=SC2086
        out="$(openssl verify $verify_opts -CAfile "$cert" "-${opt}" "$HOST" "$cert" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            SAN_CHECK_STATUS=0
        elif printf '%s' "$out" | grep -qi 'mismatch'; then
            SAN_CHECK_STATUS=1   # verification failed: the SAN does not match
        else
            SAN_CHECK_STATUS=2   # the tool itself failed, that is not a mismatch
        fi
    fi
    SAN_CHECK_DETAIL="$out"
    [ "$SAN_CHECK_STATUS" -eq 0 ]
}

if is_ipv4 "$HOST" || is_ipv6 "$HOST"; then
    SAN_TYPE=IP
    SAN_LABEL='IP Address:'
elif [[ $HOST == *.* && $HOST =~ ^[0-9.]+$ ]]; then
    # Looks like an IPv4 address but is not one (typo, out-of-range octet, too many
    # parts). Do not silently downgrade it to a DNS SAN.
    die "invalid IPv4 address '$HOST': expected four octets in 0-255"
elif is_dns_name "$HOST"; then
    SAN_TYPE=DNS
    SAN_LABEL='DNS:'
else
    die "invalid host address '$HOST': expected an IPv4 address, an IPv6 address or a DNS name (no scheme, port or path)"
fi

# safe file reader: never fails when the file is absent
rdf() { if [ -f "$1" ]; then tr -d ' \r\n' < "$1" 2>/dev/null || true; fi; }

PORT="$(rdf "$P/data/port.pl")";   [ -n "$PORT" ]  || PORT=8888
ENTRY="$(rdf "$P/data/admin_path.pl")"
SSL_BEFORE="$( [ -f "$P/data/ssl.pl" ] && echo on || echo off )"
LIMIT_BEFORE="$(rdf "$P/data/limitip.conf")"

echo "== 0. preflight =="
[ -d "$P" ] || { echo "FATAL: BT panel not found at $P" >&2; exit 1; }
echo "port=${PORT} entry=${ENTRY}"
echo "ssl_before=${SSL_BEFORE}"
echo "limitip_before=[${LIMIT_BEFORE}]"

echo "== 1. backup -> $BK =="
mkdir -p "$BK"
tar czf "$BK/panel-data.tgz" -C "$P" data 2>/dev/null || true
tar czf "$BK/panel-ssl.tgz"  -C "$P" ssl  2>/dev/null || true
for f in "$BK/panel-data.tgz" "$BK/panel-ssl.tgz"; do
    if [ ! -s "$f" ]; then echo "FATAL: backup $f is empty/missing, aborting" >&2; exit 1; fi
done
{
    echo "panel=$P"
    echo "port=$PORT"
    echo "entry=$ENTRY"
    echo "ssl_before=$SSL_BEFORE"
    echo "limitip_before=[$LIMIT_BEFORE]"
    echo "restore: tar xzf panel-data.tgz -C $P ; tar xzf panel-ssl.tgz -C $P ; /etc/init.d/bt restart"
} > "$BK/ROLLBACK.txt"
ln -sfn "$BK" /root/backups/bt-panel-harden-LAST
ls -la "$BK"

echo "== 2. panel ssl (sha256 self-signed) =="
if [ "${FORCE_SSL:-0}" = "1" ] || [ ! -s "$P/ssl/privateKey.pem" ] || [ ! -s "$P/ssl/certificate.pem" ]; then
    NEW_KEY="$BK/privateKey.pem.new"
    NEW_CRT="$BK/certificate.pem.new"
    echo "generating a new self-signed cert (SAN ${SAN_TYPE}:${HOST})"
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
        -keyout "$NEW_KEY" \
        -out "$NEW_CRT" \
        -subj "/CN=bt-he1k" \
        -addext "subjectAltName=${SAN_TYPE}:${HOST}" 2>&1 | sed 's/^/    /'; then
        echo "FATAL: openssl req failed; previous certificate and SSL state left untouched" >&2
        exit 1
    fi
    # Never install a certificate whose SAN does not actually carry the requested host
    # (that is how a literal <TEST_HOST_IP> placeholder used to end up in the panel cert).
    if ! is_live_host "$NEW_CRT"; then
        if [ "$SAN_CHECK_STATUS" -eq 2 ]; then
            echo "FATAL: could not verify the generated certificate on this host (openssl cannot match a SAN here);" >&2
            echo "  not installing it; the previous certificate and SSL state are left untouched" >&2
            [ -n "$SAN_CHECK_DETAIL" ] && echo "  openssl: $SAN_CHECK_DETAIL" >&2
            exit 1
        fi
        echo "FATAL: generated cert lacks ${SAN_LABEL}${HOST} in subjectAltName; not installing it" >&2
        echo "  actual: $(cert_san_text "$NEW_CRT")" >&2
        exit 1
    fi
    cp "$NEW_KEY" "$P/ssl/privateKey.pem"
    cp "$NEW_CRT" "$P/ssl/certificate.pem"
    echo "generated new self-signed cert"
else
    echo "cert already present, keeping it (FORCE_SSL=1 to regenerate for ${HOST})"
    if cert_san_text "$P/ssl/certificate.pem" | grep -q '<'; then
        echo "WARNING: the existing cert's subjectAltName still contains a redaction placeholder;" >&2
        echo "         rerun with FORCE_SSL=1 to replace it with ${SAN_TYPE}:${HOST}" >&2
    fi
fi
if [ ! -s "$P/ssl/privateKey.pem" ] || [ ! -s "$P/ssl/certificate.pem" ]; then
    echo "FATAL: cert generation failed, not enabling SSL" >&2
    exit 1
fi
chmod 600 "$P/ssl/privateKey.pem"
chmod 644 "$P/ssl/certificate.pem"
touch "$P/ssl/input.pl"
printf 'True' > "$P/data/ssl.pl"

echo "== 3. panel ip allowlist =="
if [ "$ALLOW" = "none" ]; then
    : > "$P/data/limitip.conf"
    echo "allowlist cleared (panel open to any source IP)"
else
    printf '%s' "$ALLOW" > "$P/data/limitip.conf"
    echo "allowlist set to [$ALLOW]"
fi
chmod 600 "$P/data/limitip.conf"

echo "== 4. restart panel =="
/etc/init.d/bt restart 2>&1 | tail -6 || true
sleep 4

echo "== 5. verify (on host) =="
# NOTE: BT panel answers 404 to requests without a browser-like User-Agent
# (anti-scanning gate). Always probe with a browser UA, or you will think the
# panel is broken when it is fine. See ADR-0002.
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
if ss -lntp 2>/dev/null | grep -q ":${PORT} "; then
    echo "port ${PORT}: LISTENING"
else
    echo "WARN: port ${PORT} not listening"
fi
echo "https_local_127=$(curl -sk -A "$UA" -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1:${PORT}${ENTRY}" || echo err)"
echo "https_no_ua=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1:${PORT}${ENTRY}" || echo err)   # expect 404: UA gate, not a fault"
echo "http_local_127=$(curl -s  -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}${ENTRY}"  || echo err)"
echo "ssl_flag=$( [ -f "$P/data/ssl.pl" ] && echo on || echo off )"
echo "limitip_after=[$(rdf "$P/data/limitip.conf")]"
echo "cert: $(openssl x509 -in "$P/ssl/certificate.pem" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')$(cert_san_text "$P/ssl/certificate.pem")"
echo "== harden complete (backup: $BK) =="
