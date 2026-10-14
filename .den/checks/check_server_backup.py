"""Acceptance: clarity/server-backup (clarity-server 2: hourly off-box copy to tunnel-bear). PROTECTED.

Brian, 2026-10-14: "Add sync to tunnel-bear like all our app." The pattern is gym-app's
rebuild-server backup.py / den-fleet's `den backup` (both rsync to tunnel-bear:backups/<app>/).
The REMOTE here is a local directory, reached only through rsync, as in gym-app's check.

    server/.venv/bin/python .den/checks/check_server_backup.py
"""
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from server_common import ROOT, Server, http, need, need_server_package, run_server_bin_check, sha, sqlite_bytes, tmpdir  # noqa: E402

need_server_package()
run_server_bin_check()
SNAP = re.compile(r"^clarity-(\d{8}T\d{6}Z)\.db$")


def tree(d: Path):
    return sorted((str(p.relative_to(d)), p.stat().st_size, p.stat().st_mtime_ns) for p in d.rglob("*") if p.is_file())


home = tmpdir()
remote = tmpdir("clarity-remote-")
env = {"CLARITY_BACKUP_DIR": str(home / "backups"), "CLARITY_BACKUP_REMOTE": str(remote) + "/"}
blobs = [sqlite_bytes(4, "r1"), sqlite_bytes(6, "r2")]
with Server(home, extra_env=env) as s:
    tok = s.pair()
    for d in blobs:
        st, b = http("POST", s.base + "/api/v1/backups", token=tok, raw=d, headers={"X-Content-Sha256": sha(d)})
        need(st == 200, f"upload failed: {st} {b}")
    # a file already on the remote that the server does not know must survive (never --delete backups/)
    (remote / "backups").mkdir(parents=True)
    (remote / "backups" / "keep-me.sqlite").write_bytes(b"older blob")

    r = s.cli("backup", "run", check=False)
    need(r.returncode == 0, f"bin/clarity backup run failed rc {r.returncode}:\n{r.stdout}\n{r.stderr}")
    snaps = [p.name for p in (remote / "hourly").glob("*.db")] if (remote / "hourly").is_dir() else []
    need(len(snaps) == 1 and SNAP.match(snaps[0]), f"the remote needs exactly one hourly/clarity-YYYYmmddTHHMMSSZ.db, got {snaps}")
    c = sqlite3.connect(remote / "hourly" / snaps[0])
    need(c.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "the remote snapshot fails integrity_check")
    c.close()
    for d in blobs:
        f = remote / "backups" / f"{sha(d)}.sqlite"
        need(f.is_file() and f.read_bytes() == d, f"the remote lacks backups/{sha(d)}.sqlite with the uploaded bytes")
    need((remote / "backups" / "keep-me.sqlite").is_file(), "backup run deleted a remote file under backups/: never --delete there")

    before = tree(remote)
    r = s.cli("backup", "verify", check=False)
    need(r.returncode == 0, f"backup verify failed on a good remote:\n{r.stdout}\n{r.stderr}")
    need(re.search(r"remote_backups=2\b", r.stdout) and f"snapshot={snaps[0]}" in r.stdout,
         f"verify must print remote_backups=N and snapshot=<name>, got: {r.stdout.strip()}")
    need(tree(remote) == before, "backup verify wrote to the remote: verify is read-only")

    def broken(why, mutate):
        bad = tmpdir("clarity-remote-bad-")
        shutil.rmtree(bad)
        shutil.copytree(remote, bad)
        mutate(bad)
        r = s.cli("backup", "verify", check=False, env={"CLARITY_BACKUP_REMOTE": str(bad) + "/"})
        need(r.returncode != 0, f"backup verify passed with {why}")
        print(f"verify refuses {why}: ok")

    broken("a missing blob", lambda d: (d / "backups" / f"{sha(blobs[0])}.sqlite").unlink())
    broken("an altered blob", lambda d: (d / "backups" / f"{sha(blobs[1])}.sqlite").write_bytes(b"tampered"))
    broken("a truncated snapshot", lambda d: (d / "hourly" / snaps[0]).write_bytes((d / "hourly" / snaps[0]).read_bytes()[:1000]))

    def stale(d):
        old = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(time.time() - 3 * 3600))
        (d / "hourly" / snaps[0]).rename(d / "hourly" / f"clarity-{old}.db")
    broken("a stale snapshot (3 h old)", stale)
    broken("an empty remote", lambda d: [shutil.rmtree(d / x) for x in ("hourly", "backups")])

    # a new upload not yet pushed fails verify until the next run
    d3 = sqlite_bytes(2, "r3")
    st, _ = http("POST", s.base + "/api/v1/backups", token=tok, raw=d3, headers={"X-Content-Sha256": sha(d3)})
    need(st == 200, "third upload failed")
    r = s.cli("backup", "verify", check=False)
    need(r.returncode != 0, "verify passed while a backup on red is not on the remote yet")
    s.cli("backup", "run")
    s.cli("backup", "verify")

for n, want in (("clarity-backup.service", ("Type=oneshot", "CLARITY_BACKUP_REMOTE=tunnel-bear:backups/clarity/",
                                            "backup run", "backup verify")),
                ("clarity-backup.timer", ("OnCalendar=hourly", "Persistent=true"))):
    f = ROOT / "deploy" / n
    need(f.is_file(), f"deploy/{n} missing")
    t = f.read_text()
    for w in want:
        need(w in t, f"deploy/{n} must contain {w!r}")
ex = [l for l in (ROOT / "deploy" / "clarity-backup.service").read_text().splitlines() if l.startswith("ExecStart=")]
need(len(ex) == 2 and "backup run" in ex[0] and "backup verify" in ex[1], f"clarity-backup.service: ExecStart run then verify, got {ex}")
print("server-backup OK")
