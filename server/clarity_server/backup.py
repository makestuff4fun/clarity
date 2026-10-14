"""clarity backup: hourly VACUUM INTO snapshots and the backup store, rsynced off-box, then verified.

Remote access is rsync only (listing and fetching included); verify never writes to the remote.
Stored backup blobs are never deleted or rewritten, locally or remotely.

    CLARITY_BACKUP_DIR     local root (default ~/backups/clarity): hourly/, daily/
    CLARITY_BACKUP_REMOTE  any rsync destination (default tunnel-bear:backups/clarity/):
                           hourly/ and daily/ mirror the local retention; backups/ only grows
"""
import hashlib
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

KEEP_HOURLY = 48
KEEP_DAILY = 60
MAX_AGE = 2 * 3600
DEFAULT_REMOTE = "tunnel-bear:backups/clarity/"
HOURLY_RE = re.compile(r"clarity-(\d{8}T\d{6}Z)\.db")
DAILY_RE = re.compile(r"clarity-(\d{8})\.db")


class BackupError(Exception):
    pass


def local_root() -> Path:
    return Path(os.path.expanduser(os.environ.get("CLARITY_BACKUP_DIR") or "~/backups/clarity"))


def remote() -> str:
    r = os.environ.get("CLARITY_BACKUP_REMOTE") or DEFAULT_REMOTE
    return r if r.endswith("/") else r + "/"


def _open_ro(path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=30)


def _prune(d: Path, pattern, keep: int) -> None:
    # Filenames carry a fixed-width UTC timestamp, so name order is time order.
    files = sorted(p for p in d.iterdir() if pattern.fullmatch(p.name))
    for p in files[:-keep]:
        p.unlink()


def snapshot(db_path: str, now: datetime) -> Path:
    root = local_root()
    hourly, daily = root / "hourly", root / "daily"
    hourly.mkdir(parents=True, exist_ok=True)
    daily.mkdir(parents=True, exist_ok=True)
    if not Path(db_path).is_file():
        raise BackupError(f"no database at {db_path}")
    target = hourly / f"clarity-{now:%Y%m%dT%H%M%SZ}.db"
    tmp = hourly / f".tmp-{target.name}"
    tmp.unlink(missing_ok=True)
    con = sqlite3.connect(db_path, timeout=30)
    try:
        con.execute("VACUUM INTO ?", (str(tmp),))
    finally:
        con.close()
    os.replace(tmp, target)
    dday = daily / f"clarity-{now:%Y%m%d}.db"
    if not dday.exists():
        tmpd = daily / f".tmp-{dday.name}"
        shutil.copyfile(target, tmpd)
        os.replace(tmpd, dday)
    _prune(hourly, HOURLY_RE, KEEP_HOURLY)
    _prune(daily, DAILY_RE, KEEP_DAILY)
    return target


def _rsync(*args) -> subprocess.CompletedProcess:
    p = subprocess.run(["rsync", *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise BackupError(f"rsync {' '.join(args)} failed rc {p.returncode}: {p.stderr.strip()}")
    return p


def push(data_dir: str) -> None:
    root = local_root()
    for sub in ("hourly", "daily"):
        (root / sub).mkdir(parents=True, exist_ok=True)
        _rsync("-a", "--checksum", "--delete", "--mkpath", "--exclude=.tmp-*",
               f"{root}/{sub}/", remote() + sub + "/")
    # Backup blobs: never --delete, never overwrite what is already there.
    src = Path(data_dir) / "backups"
    src.mkdir(parents=True, exist_ok=True)
    _rsync("-a", "--ignore-existing", "--mkpath", "--exclude=.*", "--include=*.sqlite", "--exclude=*",
           f"{src}/", remote() + "backups/")


def _list_remote(sub: str, pattern) -> list[str]:
    listing = _rsync("--list-only", remote() + sub + "/").stdout
    names = []
    for line in listing.splitlines():
        parts = line.split()
        if parts and not line.startswith("d") and pattern.fullmatch(parts[-1]):
            names.append(parts[-1])
    return sorted(names)


def verify(db_path: str, now: float) -> str:
    """Prove the remote holds a fresh, sound snapshot and every stored backup. Read-only on the
    remote. -> the summary line; BackupError on any failure."""
    if not Path(db_path).is_file():
        raise BackupError(f"no database at {db_path}")
    try:
        names = _list_remote("hourly", HOURLY_RE)
    except BackupError as e:
        raise BackupError(f"cannot list remote hourly/: {e}")
    if not names:
        raise BackupError(f"remote {remote()}hourly/ has no snapshots")
    name = names[-1]
    taken = datetime.strptime(HOURLY_RE.fullmatch(name).group(1), "%Y%m%dT%H%M%SZ") \
        .replace(tzinfo=timezone.utc).timestamp()
    if now - taken > MAX_AGE:
        raise BackupError(f"stale remote: newest snapshot {name} is {(now - taken) / 3600:.1f} h old")

    live = _open_ro(db_path)
    try:
        shas = [r[0] for r in live.execute("SELECT sha256 FROM backups ORDER BY sha256")]
    finally:
        live.close()

    with tempfile.TemporaryDirectory(prefix="clarity-verify-") as td:
        _rsync("-t", remote() + "hourly/" + name, td + "/")
        snap = Path(td) / name
        if not snap.is_file() or snap.stat().st_size == 0:
            raise BackupError(f"remote snapshot {name} is empty")
        try:
            con = _open_ro(snap)
            try:
                res = con.execute("PRAGMA integrity_check").fetchone()[0]
            finally:
                con.close()
        except sqlite3.DatabaseError as e:
            raise BackupError(f"remote snapshot {name} unreadable: {e}")
        if res != "ok":
            raise BackupError(f"remote snapshot {name} integrity_check: {res}")

        bad = []
        if shas:
            bdir = Path(td) / "backups"
            bdir.mkdir()
            list_file = Path(td) / "backups.lst"
            list_file.write_text("".join(f"{s}.sqlite\n" for s in shas))
            # Missing files make rsync exit 23; the per-file hash check below reports them.
            subprocess.run(["rsync", "-t", f"--files-from={list_file}", remote() + "backups/", f"{bdir}/"],
                           capture_output=True, text=True)
            for s in shas:
                f = bdir / f"{s}.sqlite"
                if not f.is_file():
                    bad.append(f"{s}.sqlite missing")
                elif hashlib.sha256(f.read_bytes()).hexdigest() != s:
                    bad.append(f"{s}.sqlite does not hash to its name")
        line = f"remote_backups={len(shas) - len(bad)} snapshot={name}"
        if bad:
            raise BackupError(f"remote backups/: {'; '.join(bad)}; {line} of {len(shas)}")
    return line


def run(cmd: str, db_path: str, data_dir: str) -> str:
    if cmd == "run":
        s = snapshot(db_path, datetime.now(timezone.utc))
        push(data_dir)
        return f"snapshot={s.name} pushed to {remote()}"
    if cmd == "verify":
        return f"verified: {verify(db_path, time.time())}"
    raise BackupError(f"unknown backup command {cmd}")
