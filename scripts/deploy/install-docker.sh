#!/usr/bin/env bash
# install-docker.sh - install Docker CE + compose from the OpenCloudOS EPOL repo,
# configure a reachable registry mirror, and start the daemon.
#
# Context (bt-he1k, 2026-09-28): Docker Hub is NOT reachable from this host
# (registry-1.docker.io / auth.docker.io both time out), while the DaoCloud
# mirror is reachable. So we use the mirror prefix in image references.
#
# Idempotent: re-running reinstalls nothing it does not need and rewrites daemon.json
# to the same content.
#
# Rollback:  systemctl disable --now docker ; dnf remove -y docker-ce docker-compose
#            (image data stays under /var/lib/docker unless you also rm -rf it)

set -uo pipefail

echo '########## PREFLIGHT ##########'
if command -v docker >/dev/null 2>&1; then
    echo "docker already present: $(docker --version 2>&1)"
else
    echo "docker absent, will install"
fi
echo "available in repos:"
dnf -q info docker-ce docker-compose 2>/dev/null | grep -E '^(Name|Version)' | sed 's/^/  /'

echo
echo '########## MIRROR REACHABILITY ##########'
for u in https://registry-1.docker.io/v2/ https://m.daocloud.io/v2/ https://docker.m.daocloud.io/v2/ ; do
    printf '  %-40s -> %s\n' "$u" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$u" 2>&1)"
done

echo
echo '########## INSTALL ##########'
# NOTE (OpenCloudOS 9.6): AppStream ships `moby` (Docker) which PROVIDES `docker`,
# and EPOL's `docker-ce` CONFLICTS with it, so `docker-ce + docker-compose` cannot
# resolve together (docker-compose requires `docker` -> moby -> conflict).
# The distro-native pair `moby + docker-compose` installs cleanly, so prefer it.
if rpm -q moby >/dev/null 2>&1; then
    echo "moby already installed; nothing to install"
elif dnf -q list --available moby >/dev/null 2>&1; then
    echo "using distro-native pair: moby + docker-compose"
    dnf install -y moby docker-compose 2>&1 | tail -12
else
    echo "moby unavailable, falling back to EPOL: docker-ce + docker-compose"
    dnf install -y --allowerasing docker-ce docker-compose 2>&1 | tail -12
fi
echo '--- installed packages ---'
rpm -q moby docker-compose docker-ce 2>&1 | sed 's/^/  /'
echo "  docker  binary: $(command -v docker || echo MISSING)"
echo "  dockerd binary: $(command -v dockerd || echo MISSING)"
echo "  unit file:      $(ls /usr/lib/systemd/system/docker.service /etc/systemd/system/docker.service 2>/dev/null | head -1 || echo MISSING)"

echo
echo '########## DAEMON CONFIG ##########'
mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
    cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
    echo "existing daemon.json backed up"
fi
# IMPORTANT (OpenCloudOS 9.6 moby): the shipped docker.service passes
#   --log-driver=journald
# as a flag. Setting "log-driver" (or "log-opts") in daemon.json then makes dockerd
# abort at startup with:
#   unable to configure the Docker daemon with file /etc/docker/daemon.json:
#   the following directives are specified both as a flag and in the configuration
#   file: log-driver: (from flag: journald, from file: json-file)
# So daemon.json must carry ONLY the registry mirror here; journald handles rotation.
cat > /etc/docker/daemon.json <<'EOS'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://m.daocloud.io"]
}
EOS
cat /etc/docker/daemon.json

echo
echo '########## START ##########'
systemctl enable --now docker 2>&1 | tail -3
systemctl reset-failed docker.socket docker.service docker 2>/dev/null || true
systemctl restart docker 2>&1 | tail -3
sleep 5
echo "active=$(systemctl is-active docker 2>&1) enabled=$(systemctl is-enabled docker 2>&1)"
if [ "$(systemctl is-active docker 2>&1)" != "active" ]; then
    echo '--- dockerd startup error ---'
    journalctl -u docker.service -b --no-pager --output=cat 2>/dev/null | grep -iE 'unable to configure|level=fatal|Main process exited' | tail -5
fi
docker --version 2>&1
docker compose version 2>&1 | head -1
docker-compose --version 2>&1 | head -1

echo
echo '########## INFO ##########'
docker info 2>&1 | grep -E 'Server Version|Storage Driver|Registry Mirrors|Docker Root Dir|Cgroup Version|Logging Driver|Total Memory|CPUs' | sed 's/^/  /'
echo "  disk after: $(df -h / | tail -1)"

echo
echo '########## SMOKE TEST ##########'
if timeout 120 docker pull m.daocloud.io/docker.io/library/hello-world:latest >/tmp/docker-smoke.log 2>&1; then
    docker run --rm m.daocloud.io/docker.io/library/hello-world:latest 2>&1 | grep -E 'Hello from Docker|working correctly' | head -2
    echo "pull+run OK"
else
    echo "WARN: smoke pull failed; tail of log:"
    tail -8 /tmp/docker-smoke.log
fi

echo
echo 'install-docker complete'
