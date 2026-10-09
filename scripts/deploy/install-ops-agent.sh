#!/usr/bin/env bash
# install-ops-agent.sh -- install/reinstall the loopback ops-agent on bt-he1k.
#
# Why: driving this host through one-shot ssh.exe calls costs 0.5-1 s of handshake and
# PowerShell overhead per command, cannot stream, and hits argv/stdin minefields. The
# agent is a ~300 line stdlib-only HTTP service bound to 127.0.0.1:7777 that runs
# commands, background jobs, and file transfers. It is reached from Windows through the
# existing SSH tunnel (scripts/utils/napcat-webui-tunnel.ps1), so it adds NO new public
# exposure: you still need the SSH key to get to it. See docs/decisions/ADR-0005.
#
# Usage (remote, usually via scripts/utils/ssh-bt-he1k.ps1 -ScriptPath):
#     install-ops-agent.sh <token-hex64> [port]
#
# The embedded Python is the source of truth for the agent.
set -euo pipefail

TOKEN="${1:-}"
PORT="${2:-7777}"
APP_DIR=/opt/ops-agent
ETC_DIR=/etc/ops-agent
LOG_DIR=/var/log/ops-agent
RUN_DIR=/var/run/ops-agent
PY="$(command -v python3 || true)"

die() { echo "install-ops-agent: $*" >&2; exit 1; }

[ -n "$PY" ] || die "python3 not found"
[ -n "$TOKEN" ] || die "missing token argument"
case "$TOKEN" in
    *[!0-9a-f]*) die "token must be lowercase hex" ;;
esac
[ "${#TOKEN}" -ge 64 ] || die "token too short (${#TOKEN} chars)"

echo "== 环境"
echo "   python3  : $PY ($("$PY" -V 2>&1))"
echo "   port     : $PORT"
echo "   token    : ${#TOKEN} hex chars"

install -d -m 755 "$APP_DIR" "$LOG_DIR" "$RUN_DIR"
install -d -m 700 "$ETC_DIR"
umask 077
printf '%s\n' "$TOKEN" > "$ETC_DIR/token"
chmod 600 "$ETC_DIR/token"
chown root:root "$ETC_DIR/token"
umask 022

echo
echo "== 写入 $APP_DIR/ops-agent.py"
cat > "$APP_DIR/ops-agent.py" <<'PYEOF'
#!/usr/bin/env python3
"""ops-agent -- tiny loopback-only command executor for the bt-he1k test server.

Installed by scripts/deploy/install-ops-agent.sh (which holds the source of truth).

Deliberately dependency-free: stdlib only, so it survives on OpenCloudOS 9 without
touching pip, and small enough to audit in one sitting.

Security model
--------------
* Binds 127.0.0.1 only -- it is never reachable from the internet directly.
* Every request needs `Authorization: Bearer <token>`; the token lives in
  /etc/ops-agent/token (0600 root). Comparison is constant-time.
* The only way in from outside is the SSH tunnel, so reaching the agent already
  requires the SSH private key. The agent therefore does not widen the attack
  surface, but the token must still be treated as a root password: the agent runs
  as root and executes arbitrary shell.
* Every request is appended to /var/log/ops-agent/commands.log as one JSON line.
"""

import base64
import hmac
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

VERSION = "1.0.0"
BIND_ADDR = "127.0.0.1"
PORT = int(os.environ.get("OPS_AGENT_PORT", "7777"))
TOKEN_FILE = os.environ.get("OPS_AGENT_TOKEN_FILE", "/etc/ops-agent/token")
LOG_FILE = os.environ.get("OPS_AGENT_LOG", "/var/log/ops-agent/commands.log")
RUN_DIR = os.environ.get("OPS_AGENT_RUN_DIR", "/var/run/ops-agent")

MAX_OUT = 1 << 20          # bytes kept per stream (tail is kept, head is dropped)
MAX_BODY = 32 << 20        # request body cap
DEFAULT_TIMEOUT = 300
MAX_TIMEOUT = 7200
MAX_JOBS = 16
JOB_TTL = 6 * 3600
LOG_ROTATE = 8 << 20

STARTED = time.time()
JOBS = {}
JOBS_LOCK = threading.Lock()
LOG_LOCK = threading.Lock()


def load_token():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError as exc:
        raise SystemExit("ops-agent: cannot read token file %s: %s" % (TOKEN_FILE, exc))
    if len(token) < 32:
        raise SystemExit("ops-agent: token file must hold at least 32 characters")
    return token


TOKEN = load_token()


def log(record):
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    line = json.dumps(record, ensure_ascii=False)
    with LOG_LOCK:
        try:
            if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_ROTATE:
                shutil.move(LOG_FILE, LOG_FILE + ".1")
            with open(LOG_FILE, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


class Tail(object):
    """Keeps the last `cap` bytes of a stream without bounding the read."""

    def __init__(self, cap):
        self.cap = cap
        self.buf = b""
        self.total = 0

    def feed(self, chunk):
        self.total += len(chunk)
        if len(chunk) >= self.cap:
            self.buf = chunk[-self.cap:]
        else:
            self.buf = (self.buf + chunk)[-self.cap:]

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def truncated(self):
        return self.total > len(self.buf)


def _pump(pipe, tail):
    try:
        while True:
            chunk = pipe.read(65536)
            if not chunk:
                break
            tail.feed(chunk)
    except (OSError, ValueError):
        pass
    finally:
        try:
            pipe.close()
        except OSError:
            pass


def _launch(argv, cwd):
    return subprocess.Popen(
        argv,
        cwd=cwd or "/root",
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env=dict(os.environ, TERM="dumb"),
    )


def _killpg(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass


def _collect(proc, timeout):
    out, err = Tail(MAX_OUT), Tail(MAX_OUT)
    t_out = threading.Thread(target=_pump, args=(proc.stdout, out))
    t_err = threading.Thread(target=_pump, args=(proc.stderr, err))
    t_out.daemon = t_err.daemon = True
    t_out.start()
    t_err.start()
    timed_out = False
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        _killpg(proc)
        try:
            code = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            code = -9
    t_out.join(5)
    t_err.join(5)
    return code, timed_out, out, err


def run_sync(argv, cwd, timeout, label):
    started = time.time()
    proc = _launch(argv, cwd)
    code, timed_out, out, err = _collect(proc, timeout)
    result = {
        "exit": None if timed_out else code,
        "timeout": timed_out,
        "stdout": out.text(),
        "stderr": err.text(),
        "stdout_bytes": out.total,
        "stderr_bytes": err.total,
        "stdout_truncated": out.truncated(),
        "stderr_truncated": err.truncated(),
        "duration_ms": int((time.time() - started) * 1000),
    }
    log({"kind": "run", "cmd": label, "cwd": cwd or "/root", "exit": result["exit"],
         "timeout": timed_out, "ms": result["duration_ms"], "out": out.total, "err": err.total})
    return result


def _reap():
    now = time.time()
    with JOBS_LOCK:
        for jid in [k for k, v in JOBS.items()
                    if v["state"] != "running" and v["ended"] and now - v["ended"] > JOB_TTL]:
            JOBS.pop(jid, None)


def spawn(argv, cwd, timeout, label):
    _reap()
    with JOBS_LOCK:
        running = sum(1 for v in JOBS.values() if v["state"] == "running")
        if running >= MAX_JOBS:
            return None, "too many running jobs (%d)" % running
    proc = _launch(argv, cwd)
    job_id = uuid.uuid4().hex[:12]
    job = {"id": job_id, "cmd": label, "cwd": cwd or "/root", "state": "running",
           "started": time.time(), "ended": None, "exit": None, "timeout": False,
           "stdout": "", "stderr": "", "stdout_bytes": 0, "stderr_bytes": 0,
           "pid": proc.pid}
    with JOBS_LOCK:
        JOBS[job_id] = job

    def worker():
        code, timed_out, out, err = _collect(proc, timeout)
        with JOBS_LOCK:
            job.update(state="done", ended=time.time(), exit=None if timed_out else code,
                       timeout=timed_out, stdout=out.text(), stderr=err.text(),
                       stdout_bytes=out.total, stderr_bytes=err.total,
                       stdout_truncated=out.truncated(), stderr_truncated=err.truncated())
        log({"kind": "job", "id": job_id, "cmd": label, "exit": job["exit"],
             "timeout": timed_out, "ms": int((job["ended"] - job["started"]) * 1000)})

    threading.Thread(target=worker).start()
    log({"kind": "spawn", "id": job_id, "cmd": label, "cwd": cwd or "/root"})
    return job_id, None


def public_job(job, full=True):
    out = {k: v for k, v in job.items() if k not in ("stdout", "stderr")}
    if full:
        out["stdout"] = job.get("stdout", "")
        out["stderr"] = job.get("stderr", "")
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "ops-agent/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # -- helpers ---------------------------------------------------------------
    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _auth(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            # With HTTP/1.1 keep-alive an unread request body would desync the next
            # request on this socket, so always close on an auth failure.
            self.close_connection = True
            self._send(401, {"ok": False, "error": "missing bearer token"})
            return False
        if not hmac.compare_digest(header[7:].strip(), TOKEN):
            self.close_connection = True
            log({"kind": "auth", "result": "denied", "peer": self.client_address[0]})
            self._send(403, {"ok": False, "error": "bad token"})
            return False
        return True

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.close_connection = True
            self._send(413, {"ok": False, "error": "body too large"})
            return None
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            self._send(400, {"ok": False, "error": "bad json: %s" % exc})
            return None

    def _timeout(self, payload):
        try:
            value = int(payload.get("timeout", DEFAULT_TIMEOUT))
        except (TypeError, ValueError):
            value = DEFAULT_TIMEOUT
        return max(1, min(value, MAX_TIMEOUT))

    def _cwd(self, payload):
        cwd = payload.get("cwd") or "/root"
        return cwd if os.path.isdir(cwd) else None

    def _script_argv(self, payload):
        """Write the posted script to a temp file and hand back the argv + cleanup."""
        text = payload.get("script")
        if not isinstance(text, str) or not text.strip():
            self._send(400, {"ok": False, "error": "missing script"})
            return None, None
        args = payload.get("args") or []
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            self._send(400, {"ok": False, "error": "args must be a list of strings"})
            return None, None
        path = os.path.join(RUN_DIR, "script-%s.sh" % uuid.uuid4().hex[:12])
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text if text.endswith("\n") else text + "\n")
        os.chmod(path, 0o700)
        return ["bash", path] + list(args), path

    # -- routes ----------------------------------------------------------------
    def do_GET(self):
        if not self._auth():
            return
        parsed = urlparse(self.path)
        path = parsed.path
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        if path == "/health":
            self._send(200, {"ok": True, "version": VERSION, "host": os.uname().nodename,
                             "uptime_s": int(time.time() - STARTED), "port": PORT,
                             "python": sys.version.split()[0], "pid": os.getpid()})
        elif path == "/jobs":
            with JOBS_LOCK:
                items = sorted(JOBS.values(), key=lambda j: j["started"], reverse=True)
                self._send(200, {"ok": True, "jobs": [public_job(j, False) for j in items]})
        elif path == "/job":
            with JOBS_LOCK:
                job = JOBS.get(params.get("id", ""))
                payload = public_job(job) if job else None
            if job is None:
                self._send(404, {"ok": False, "error": "no such job"})
            else:
                self._send(200, dict({"ok": True}, **payload))
        elif path == "/get":
            target = params.get("path", "")
            if not target or not os.path.isfile(target):
                self._send(404, {"ok": False, "error": "no such file"})
                return
            with open(target, "rb") as fh:
                data = fh.read()
            self._send(200, {"ok": True, "path": target, "size": len(data),
                             "data_b64": base64.b64encode(data).decode("ascii")})
        elif path == "/ls":
            target = params.get("path") or "/root"
            if not os.path.isdir(target):
                self._send(404, {"ok": False, "error": "no such directory"})
                return
            entries = []
            for name in sorted(os.listdir(target)):
                full = os.path.join(target, name)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                entries.append({"name": name, "dir": os.path.isdir(full), "size": st.st_size,
                                "mode": oct(st.st_mode & 0o7777),
                                "mtime": int(st.st_mtime)})
            self._send(200, {"ok": True, "path": target, "entries": entries})
        else:
            self._send(404, {"ok": False, "error": "unknown route %s" % path})

    def do_POST(self):
        if not self._auth():
            return
        path = urlparse(self.path).path
        payload = self._body()
        if payload is None:
            return
        if path == "/run":
            cmd = payload.get("cmd")
            if not isinstance(cmd, str) or not cmd.strip():
                self._send(400, {"ok": False, "error": "missing cmd"})
                return
            result = run_sync(["bash", "-lc", cmd], self._cwd(payload), self._timeout(payload), cmd)
            self._send(200, dict({"ok": True}, **result))
        elif path == "/script":
            argv, tmp = self._script_argv(payload)
            if argv is None:
                return
            try:
                label = "[script %d bytes] %s" % (len(payload["script"]),
                                                  (payload.get("name") or tmp))
                result = run_sync(argv, self._cwd(payload), self._timeout(payload), label)
            finally:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
            self._send(200, dict({"ok": True}, **result))
        elif path == "/spawn":
            cmd = payload.get("cmd")
            if not isinstance(cmd, str) or not cmd.strip():
                self._send(400, {"ok": False, "error": "missing cmd"})
                return
            job_id, err = spawn(["bash", "-lc", cmd], self._cwd(payload),
                                self._timeout(payload), cmd)
            if job_id is None:
                self._send(429, {"ok": False, "error": err})
            else:
                self._send(200, {"ok": True, "id": job_id})
        elif path == "/put":
            target = payload.get("path")
            data = payload.get("content_b64")
            if not target or not isinstance(data, str):
                self._send(400, {"ok": False, "error": "need path and content_b64"})
                return
            parent = os.path.dirname(target)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(target, "wb") as fh:
                fh.write(base64.b64decode(data))
            mode = payload.get("mode")
            os.chmod(target, int(mode, 8) if isinstance(mode, str) else int(mode or 0o644))
            log({"kind": "put", "path": target, "size": os.path.getsize(target)})
            self._send(200, {"ok": True, "path": target, "size": os.path.getsize(target)})
        elif path == "/kill":
            job_id = payload.get("id", "")
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job or job["state"] != "running":
                self._send(404, {"ok": False, "error": "no such running job"})
                return
            try:
                os.killpg(os.getpgid(job["pid"]), signal.SIGTERM)
            except OSError as exc:
                self._send(500, {"ok": False, "error": str(exc)})
                return
            log({"kind": "kill", "id": job_id})
            self._send(200, {"ok": True, "id": job_id})
        else:
            self._send(404, {"ok": False, "error": "unknown route %s" % path})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.makedirs(RUN_DIR, exist_ok=True)
    srv = Server((BIND_ADDR, PORT), Handler)
    log({"kind": "start", "version": VERSION, "bind": "%s:%d" % (BIND_ADDR, PORT)})
    print("ops-agent %s listening on %s:%d (pid %d)" % (VERSION, BIND_ADDR, PORT, os.getpid()),
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
PYEOF
chmod 755 "$APP_DIR/ops-agent.py"
"$PY" -c "import ast,sys; ast.parse(open('$APP_DIR/ops-agent.py').read())" \
    || die "embedded python does not parse"

echo
echo "== 写入 systemd 单元"
cat > /etc/systemd/system/ops-agent.service <<UNIT
[Unit]
Description=ops-agent - loopback command executor for bt-he1k
After=network.target

[Service]
Type=simple
User=root
Environment=OPS_AGENT_PORT=$PORT
ExecStart=$PY $APP_DIR/ops-agent.py
Restart=always
RestartSec=2
SyslogIdentifier=ops-agent

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/ops-agent.service

echo
echo "== 启动服务"
/usr/bin/systemctl daemon-reload
/usr/bin/systemctl enable ops-agent.service >/dev/null 2>&1 || true
/usr/bin/systemctl restart ops-agent.service
for i in $(seq 1 20); do
    if /usr/bin/systemctl is-active --quiet ops-agent.service; then break; fi
    sleep 0.5
done
/usr/bin/systemctl is-active --quiet ops-agent.service \
    || { journalctl -u ops-agent.service -n 30 --no-pager; die "service failed to start"; }

echo
echo "== 自检"
for i in $(seq 1 20); do
    health=$(curl -s -m 5 -H "Authorization: Bearer $TOKEN" \
        "http://127.0.0.1:$PORT/health" 2>/dev/null || true)
    [ -n "$health" ] && break
    sleep 0.5
done
if [ -z "${health:-}" ]; then
    journalctl -u ops-agent.service -n 30 --no-pager
    die "agent is not answering on 127.0.0.1:$PORT"
fi
echo "   $health"
printf '   无 token -> http_code='; curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/health"
printf '   错 token -> http_code='; curl -s -m 5 -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer deadbeef" "http://127.0.0.1:$PORT/health"
curl -s -m 15 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"cmd":"id -u; uptime -p; hostname","timeout":10}' "http://127.0.0.1:$PORT/run"; echo
echo
echo "== 监听面（必须只有 127.0.0.1）"
ss -lntp 2>/dev/null | grep -E ":$PORT\b" || echo "   (ss 无输出)"
echo
echo "install-ops-agent: done"
