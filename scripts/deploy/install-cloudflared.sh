#!/usr/bin/env bash
# install-cloudflared.sh - install the cloudflared binary (no repo config needed).
set -uo pipefail

BIN=/usr/local/bin/cloudflared

if [ -x "$BIN" ]; then
    echo "already installed: $($BIN --version)"
    exit 0
fi

echo '########## PLATFORM ##########'
arch=$(uname -m)
case "$arch" in
    x86_64)  asset=cloudflared-linux-amd64 ;;
    aarch64) asset=cloudflared-linux-arm64 ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
echo "  $arch -> $asset"

echo
echo '########## DOWNLOAD ##########'
url="https://github.com/cloudflare/cloudflared/releases/latest/download/$asset"
echo "  $url"
if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$BIN.tmp" "$url"; then
    echo '  github direct failed, trying the daocloud gh mirror'
    curl -fL --retry 3 --connect-timeout 20 \
        -o "$BIN.tmp" "https://m.daocloud.io/github.com/cloudflare/cloudflared/releases/latest/download/$asset" || {
        echo 'FATAL: download failed' >&2
        exit 1
    }
fi
chmod 755 "$BIN.tmp"
mv "$BIN.tmp" "$BIN"

echo
echo '########## VERIFY ##########'
"$BIN" --version
ls -la "$BIN"
echo "  sha256: $(sha256sum "$BIN" | cut -d' ' -f1)"

echo
echo '########## PREPARE /etc/cloudflared ##########'
mkdir -p /etc/cloudflared
chmod 700 /etc/cloudflared
ls -la /etc/cloudflared

echo
echo 'install-cloudflared complete'
