"""Acceptance: clarity/server (clarity-server 1: pairing + backup store). PROTECTED (.den/**).

Brian, 2026-10-14: "Add sync to tunnel-bear like all our app." Clarity's data lives only on the
phone; the fleet pattern is phone -> its own server on red -> tunnel-bear (gym-app's
rebuild-server). This check starts the REAL server from this worktree on a temp DB and proves the
pinned contract in .den/tasks/server.yaml.

    server/.venv/bin/python .den/checks/check_server.py
"""
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).parent))
from server_common import (ROOT, Server, error_shape, http, need, need_server_package,  # noqa: E402
                           run_server_bin_check, sha, sqlite_bytes, tmpdir)

need_server_package()
run_server_bin_check()

home = tmpdir()
with Server(home) as s:
    st, b = http("GET", s.base + "/api/v1/health")
    need(st == 200 and isinstance(b, dict) and b.get("ok") is True and isinstance(b.get("version"), str),
         f"GET /api/v1/health -> {st} {b}")

    pc = s.pair_code("find-n6")
    need(isinstance(pc.get("code"), str) and len(pc["code"].split()) == 8, f"pair --json code must be 8 words: {pc}")
    need(pc.get("link") == "clarity://provision?code=" + quote(pc["code"]),
         f"pair --json link must be clarity://provision?code=<urlencoded code>, got {pc.get('link')!r}")
    need(isinstance(pc.get("expires"), (int, float)), f"pair --json needs expires (epoch): {pc}")

    st, b = http("POST", s.base + "/api/v1/pair", {"code": "not a real code at all no", "name": "x"})
    need(st == 401 and error_shape(b), f"a bad pairing code must be 401 in the error shape, got {st} {b}")
    st, b = http("POST", s.base + "/api/v1/pair", {"code": pc["code"].replace(" ", "-").upper(), "name": "find-n6",
                                                    "platform": "android", "app_version": "check"})
    need(st == 200 and isinstance(b, dict) and len(b.get("token", "")) >= 40, f"pairing (hyphens, upper case) -> {st} {b}")
    tok = b["token"]
    st, b = http("POST", s.base + "/api/v1/pair", {"code": pc["code"], "name": "again"})
    need(st == 401, f"a used pairing code must be 401, got {st}")
    need(not any(tok.encode() in f.read_bytes() for f in home.glob("clarity.db*")), "the token is stored in clear: store only its sha256")

    for t in (None, "nope-" + "x" * 40):
        st, b = http("GET", s.base + "/api/v1/backups", token=t)
        need(st == 401 and error_shape(b), f"GET /api/v1/backups with token {t!r} -> {st} {b}, want 401")
    st, b = http("GET", s.base + "/api/v1/nonesuch", token=tok)
    need(st == 404 and error_shape(b), f"an unknown /api/v1 route must be 404 in the error shape, got {st} {b}")

    db1, db2 = sqlite_bytes(5, "a"), sqlite_bytes(9, "b")
    st, b = http("POST", s.base + "/api/v1/backups", token=tok, raw=b"hello, not sqlite",
                 headers={"X-Content-Sha256": sha(b"hello, not sqlite")})
    need(st == 400 and error_shape(b), f"a non-SQLite upload must be 400, got {st} {b}")
    st, b = http("POST", s.base + "/api/v1/backups", token=tok, raw=db1, headers={"X-Content-Sha256": "0" * 64})
    need(st == 400 and error_shape(b), f"a sha256 mismatch must be 400, got {st} {b}")
    st, b1 = http("POST", s.base + "/api/v1/backups", token=tok, raw=db1, headers={"X-Content-Sha256": sha(db1)})
    need(st == 200 and isinstance(b1, dict) and b1.get("sha256") == sha(db1) and b1.get("bytes") == len(db1)
         and isinstance(b1.get("id"), str) and isinstance(b1.get("ts"), (int, float)),
         f"POST /api/v1/backups -> {st} {b1}; want {{id, sha256, bytes, ts}}")
    st, again = http("POST", s.base + "/api/v1/backups", token=tok, raw=db1, headers={"X-Content-Sha256": sha(db1)})
    need(st == 200 and again.get("id") == b1["id"], f"the same bytes again must answer the same id (dedup), got {st} {again}")
    st, b2 = http("POST", s.base + "/api/v1/backups", token=tok, raw=db2, headers={"X-Content-Sha256": sha(db2)})
    need(st == 200 and b2.get("id") != b1["id"], f"a second backup -> {st} {b2}")

    st, lst = http("GET", s.base + "/api/v1/backups", token=tok)
    need(st == 200 and isinstance(lst, dict) and isinstance(lst.get("backups"), list), f"GET /api/v1/backups -> {st} {lst}")
    ids = [x.get("id") for x in lst["backups"]]
    need(ids == [b2["id"], b1["id"]], f"GET /api/v1/backups must list both, newest first, once each: {ids}")
    need(all({"id", "sha256", "bytes", "ts", "device"} <= set(x) for x in lst["backups"]),
         f"each backup needs id, sha256, bytes, ts, device: {lst['backups']}")
    st, got = http("GET", s.base + f"/api/v1/backups/{b1['id']}", token=tok, binary=True)
    need(st == 200 and got == db1, f"GET /api/v1/backups/<id> must return the exact bytes (got {st})")
    st, b = http("GET", s.base + "/api/v1/backups/does-not-exist", token=tok)
    need(st == 404 and error_shape(b), f"an unknown backup must be 404, got {st} {b}")
    for d in (db1, db2):
        f = home / "data" / "backups" / f"{sha(d)}.sqlite"
        need(f.is_file() and f.read_bytes() == d, f"{f} must hold the uploaded bytes (server-backup mirrors data/backups/)")

    s.cli("device", "revoke", "find-n6")
    st, b = http("GET", s.base + "/api/v1/backups", token=tok)
    need(st == 401, f"a revoked device must get 401 on its next request, got {st}")
    tok2 = s.pair("find-n6-2")

with Server(home) as s:
    st, lst = http("GET", s.base + "/api/v1/backups", token=tok2)
    need(st == 200 and [x["id"] for x in lst["backups"]] == [b2["id"], b1["id"]], "backups must survive a restart")

unit = ROOT / "deploy" / "clarity-server.service"
need(unit.is_file(), "deploy/clarity-server.service missing")
u = unit.read_text()
for w in ("clarity_server.app:app_from_env", "--port 8796", "--host 127.0.0.1", "CLARITY_DB=", "CLARITY_DATA="):
    need(w in u, f"deploy/clarity-server.service must contain {w!r}")
r = subprocess.run(["systemd-analyze", "--user", "verify", str(unit)], capture_output=True, text=True)
own = [l for l in r.stderr.splitlines() if "clarity-server.service" in l and "is not executable" not in l]
need(not own, "systemd-analyze verify deploy/clarity-server.service:\n" + "\n".join(own))
tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split()
need(not [t for t in tracked if t.endswith((".db", ".sqlite")) or "/.venv" in t or t.startswith("server/.venv")],
     "a database or venv is tracked")
print("server OK")
