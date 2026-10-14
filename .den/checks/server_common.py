"""Shared helpers for clarity-server's acceptance checks. PROTECTED (.den/**). Adapted from gym-app's.

Hermetic: every check makes its own temp DB and data dir and starts the REAL app from this
worktree's server/ under uvicorn on a free loopback port. Nothing touches ~/.local/share/clarity,
~/.config or systemd. Run from the repo root with the server venv:
    server/.venv/bin/python .den/checks/check_server.py
"""
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path.cwd().resolve()
assert (ROOT / ".den").is_dir(), f"run from the clarity repo root, not {ROOT}"
CHK = ROOT / ".den" / "checks"
SERVER = ROOT / "server"
PY = str(SERVER / ".venv" / "bin" / "python")
CLARITY = str(ROOT / "bin" / "clarity")


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def need(cond, msg):
    if not cond:
        fail(msg)


def need_server_package():
    need((SERVER / "clarity_server" / "app.py").is_file(), "server/clarity_server/app.py missing (clarity-server not built yet)")
    need(os.access(CLARITY, os.X_OK), "bin/clarity missing or not executable")


def run_server_bin_check():
    c = SERVER / "bin" / "check"
    need(os.access(c, os.X_OK), "server/bin/check missing or not executable")
    r = subprocess.run([str(c)], cwd=SERVER, capture_output=True, text=True, timeout=900)
    need(r.returncode == 0, f"server/bin/check failed:\n{r.stdout[-3000:]}\n{r.stderr[-2000:]}")
    print("server/bin/check ok")


def tmpdir(prefix="clarity-check-") -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def sqlite_bytes(rows=3, tag="x") -> bytes:
    """A real SQLite database file (what Clarity's backup uploads), distinct per tag."""
    d = tmpdir()
    p = d / "b.sqlite"
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    c.executemany("INSERT INTO t (v) VALUES (?)", [(f"{tag}-{i}",) for i in range(rows)])
    c.commit()
    c.close()
    return p.read_bytes()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class Server:
    """The real app (clarity_server.app:app_from_env) under uvicorn on 127.0.0.1:<free port>."""

    def __init__(self, home: Path | None = None, extra_env=None):
        self.home = home or tmpdir()
        self.db = self.home / "clarity.db"
        self.data = self.home / "data"
        self.env = {**os.environ, "CLARITY_DB": str(self.db), "CLARITY_DATA": str(self.data),
                    "PYTHONPATH": str(SERVER), **(extra_env or {})}
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}"
        self.proc = None

    def __enter__(self):
        self.home.mkdir(parents=True, exist_ok=True)
        self.log = open(self.home / "server.log", "w")
        self.proc = subprocess.Popen(
            [PY, "-m", "uvicorn", "--factory", "clarity_server.app:app_from_env",
             "--host", "127.0.0.1", "--port", str(self.port)],
            cwd=SERVER, env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(150):
            try:
                if http("GET", self.base + "/api/v1/health")[0] == 200:
                    return self
            except OSError:
                pass
            if self.proc.poll() is not None:
                break
            time.sleep(0.1)
        self.__exit__()
        fail(f"clarity-server did not come up on {self.base}:\n" + (self.home / "server.log").read_text()[-3000:])

    def __exit__(self, *a):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()

    def cli(self, *args, check=True, env=None):
        r = subprocess.run([CLARITY, *args], cwd=ROOT, env={**self.env, **(env or {})}, capture_output=True, text=True, timeout=300)
        if check:
            need(r.returncode == 0, f"bin/clarity {' '.join(args)} failed rc {r.returncode}:\n{r.stdout}\n{r.stderr}")
        return r

    def pair_code(self, name="find-n6"):
        out = self.cli("device", "pair", name, "--json").stdout.strip()
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            fail(f"`bin/clarity device pair --json` must print one JSON object, got:\n{out}")

    def pair(self, name="find-n6") -> str:
        code = self.pair_code(name)["code"]
        st, body = http("POST", self.base + "/api/v1/pair", {"code": code, "name": name, "platform": "android", "app_version": "check"})
        need(st == 200 and isinstance(body, dict) and "token" in body, f"pairing failed: {st} {body}")
        return body["token"]


def http(method, url, body=None, token=None, headers=None, raw: bytes | None = None, timeout=30, binary=False):
    """-> (status, parsed JSON or text, or bytes when binary=True). body is JSON; raw is sent as-is."""
    h = {"Accept": "application/json", **(headers or {})}
    data = None
    if raw is not None:
        data = raw
        h.setdefault("Content-Type", "application/octet-stream")
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = f"Bearer {token}"
    if method == "POST":
        h.setdefault("Idempotency-Key", str(uuid.uuid4()))
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            st, payload = r.status, r.read()
    except urllib.error.HTTPError as e:
        st, payload = e.code, e.read()
    if binary and st == 200:
        return st, payload
    txt = payload.decode(errors="replace")
    try:
        return st, json.loads(txt) if txt else None
    except json.JSONDecodeError:
        return st, txt


def error_shape(body) -> bool:
    return (isinstance(body, dict) and isinstance(body.get("error"), dict)
            and isinstance(body["error"].get("code"), str) and isinstance(body["error"].get("message"), str))
