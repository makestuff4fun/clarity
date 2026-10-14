"""The backup store: each upload is a whole SQLite file from the phone, kept as
DATA/backups/<sha256>.sqlite plus a row in `backups`. The same bytes twice are one backup.
The server never deletes a backup (server-backup mirrors DATA/backups/ off the box)."""
import hashlib
import os
import secrets
from pathlib import Path

from .errors import ApiError

MAX_BYTES = 64 * 1024 * 1024
SQLITE_MAGIC = b"SQLite format 3\0"


def backup_dir(data_dir: str) -> Path:
    return Path(data_dir) / "backups"


def _row(r) -> dict:
    return {"id": r["id"], "sha256": r["sha256"], "bytes": r["bytes"], "ts": r["ts"], "device": r["device"]}


def store(con, data_dir: str, raw: bytes, claimed_sha: str, device: str, now: float) -> dict:
    if len(raw) > MAX_BYTES:
        raise ApiError(413, "too_large", f"a backup may be at most {MAX_BYTES} bytes")
    if not raw.startswith(SQLITE_MAGIC):
        raise ApiError(400, "not_sqlite", "the body is not a SQLite database file")
    digest = hashlib.sha256(raw).hexdigest()
    if (claimed_sha or "").strip().lower() != digest:
        raise ApiError(400, "sha_mismatch", "X-Content-Sha256 does not match the body's sha256")
    d = backup_dir(data_dir)
    d.mkdir(parents=True, exist_ok=True)
    final = d / f"{digest}.sqlite"
    if not (final.is_file() and final.stat().st_size == len(raw)):
        tmp = d / f".{digest}.{secrets.token_hex(4)}.part"
        try:
            with open(tmp, "wb") as f:
                f.write(raw)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, final)
        finally:
            tmp.unlink(missing_ok=True)
    con.execute("INSERT OR IGNORE INTO backups(id, sha256, bytes, ts, device) VALUES (?,?,?,?,?)",
                (secrets.token_hex(8), digest, len(raw), now, device))
    return _row(con.execute("SELECT * FROM backups WHERE sha256=?", (digest,)).fetchone())


def listing(con) -> list[dict]:
    return [_row(r) for r in con.execute("SELECT * FROM backups ORDER BY ts DESC, rowid DESC")]


def path_of(con, data_dir: str, backup_id: str) -> Path:
    r = con.execute("SELECT sha256 FROM backups WHERE id=?", (backup_id,)).fetchone()
    p = backup_dir(data_dir) / f"{r['sha256']}.sqlite" if r else None
    if p is None or not p.is_file():
        raise ApiError(404, "not_found", "no such backup")
    return p
