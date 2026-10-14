"""Per-device auth: a phone pairs once with a one-time code (8 words, ~80 bits, 10 minutes,
single use, stored as sha256) and gets a 256-bit bearer token, of which only the sha256 is
stored. Scopes: backup (upload, list and fetch backups). Revocation takes effect on the
device's next request."""
import hashlib
import re
import secrets
import threading
from collections import deque
from pathlib import Path
from urllib.parse import quote

from .errors import ApiError

SCOPES = ("backup",)
DEFAULT_SCOPES = "backup"
CODE_WORDS = 8
CODE_TTL = 600                 # a pairing code is valid 10 minutes
FAIL_LIMIT = 10                # 10 failures ...
FAIL_WINDOW = 60               # ... within 60 s ...
LOCKOUT = 15 * 60              # ... lock the client IP out for 15 minutes
WORDLIST = Path(__file__).parent / "data" / "pair-words.txt"

_words: list[str] | None = None


def words() -> list[str]:
    global _words
    if _words is None:
        _words = [w for w in WORDLIST.read_text().split("\n") if w and not w.startswith("#")]
    return _words


def sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def normalize_code(code: str) -> str:
    """Any case, words separated by spaces and/or hyphens -> 'w1 w2 ... w8'."""
    return " ".join(w for w in re.split(r"[\s\-]+", code.strip().lower()) if w)


def parse_scopes(scopes: str) -> list[str]:
    out = scopes.replace(",", " ").split()
    bad = [s for s in out if s not in SCOPES]
    if bad or not out:
        raise ApiError(400, "bad_scopes", f"scopes must be some of: {' '.join(SCOPES)}")
    return [s for s in SCOPES if s in out]


def client_ip(peer: str, xff: str | None) -> str:
    """The peer address; when the peer is 127.0.0.1 (Caddy), the rightmost
    X-Forwarded-For entry, the one Caddy appended. Anyone else's is ignored."""
    if peer == "127.0.0.1" and xff:
        last = xff.split(",")[-1].strip()
        if last:
            return last
    return peer


class Lockout:
    """FAIL_LIMIT failures within FAIL_WINDOW seconds from one IP -> that IP gets
    401 for LOCKOUT seconds. In memory: a restart forgets it."""

    def __init__(self):
        self._fails: dict[str, deque] = {}
        self._until: dict[str, float] = {}
        self._mu = threading.Lock()

    def locked(self, ip: str, now: float) -> bool:
        with self._mu:
            until = self._until.get(ip)
            if until is not None and until <= now:
                del self._until[ip]
                until = None
            return until is not None

    def fail(self, ip: str, now: float) -> None:
        with self._mu:
            q = self._fails.setdefault(ip, deque())
            q.append(now)
            while q and q[0] <= now - FAIL_WINDOW:
                q.popleft()
            if len(q) >= FAIL_LIMIT:
                self._until[ip] = now + LOCKOUT
                q.clear()


# ----------------------------------------------------------- pairing ---
def new_pair_code(con, name: str, scopes: str, now: float) -> str:
    """Create a one-time code for device `name`; returns 'w1 w2 ... w8'."""
    name = name.strip()
    if not name:
        raise ApiError(400, "bad_name", "device name is empty")
    sc = " ".join(parse_scopes(scopes))
    wl = words()
    code = " ".join(secrets.choice(wl) for _ in range(CODE_WORDS))
    con.execute("DELETE FROM pair_codes WHERE expires < ?", (now - 86400,))
    con.execute("INSERT INTO pair_codes(code_sha256, name, scopes, created, expires) VALUES (?,?,?,?,?)",
                (sha256(code), name, sc, now, now + CODE_TTL))
    return code


def pair_link(code: str) -> str:
    return f"clarity://provision?code={quote(code)}"


def redeem(con, code: str, platform: str, app_version: str, now: float) -> dict:
    """Redeem a pairing code. ApiError(401) on a wrong, used or expired code. The device
    takes the name given at `clarity device pair`, replacing any earlier device of that name."""
    h = sha256(normalize_code(code))
    con.execute("BEGIN IMMEDIATE")
    try:
        cur = con.execute("UPDATE pair_codes SET used=1 WHERE code_sha256=? AND used=0 AND expires > ?", (h, now))
        if cur.rowcount != 1:
            raise ApiError(401, "bad_code", "pairing code is wrong, used or expired")
        row = con.execute("SELECT name, scopes FROM pair_codes WHERE code_sha256=?", (h,)).fetchone()
        token = secrets.token_urlsafe(32)
        con.execute("INSERT INTO devices(name, token_sha256, scopes, created, platform, app_version) "
                    "VALUES (?,?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET token_sha256=excluded.token_sha256, "
                    "scopes=excluded.scopes, created=excluded.created, platform=excluded.platform, "
                    "app_version=excluded.app_version, revoked=0, last_seen=NULL, last_ip=NULL",
                    (row["name"], sha256(token), row["scopes"], now, platform, app_version))
        con.execute("COMMIT")
    except BaseException:
        con.execute("ROLLBACK")
        raise
    return {"token": token, "device": row["name"], "scopes": row["scopes"].split()}


# -------------------------------------------------------------- tokens ---
def authenticate(con, token: str, ip: str, now: float) -> dict | None:
    """The device for a live token (stamping last_seen / last_ip), else None."""
    row = con.execute("SELECT * FROM devices WHERE token_sha256=? AND revoked=0", (sha256(token),)).fetchone()
    if row is None:
        return None
    con.execute("UPDATE devices SET last_seen=?, last_ip=? WHERE name=?", (now, ip, row["name"]))
    d = dict(row)
    d["scopes"] = d["scopes"].split()
    return d


def list_devices(con) -> list[dict]:
    return [{"name": r["name"], "scopes": r["scopes"].split(), "created": r["created"],
             "last_seen": r["last_seen"], "last_ip": r["last_ip"], "platform": r["platform"],
             "app_version": r["app_version"], "revoked": bool(r["revoked"])}
            for r in con.execute("SELECT * FROM devices ORDER BY created")]


def revoke(con, name: str) -> bool:
    return con.execute("UPDATE devices SET revoked=1 WHERE name=? AND revoked=0", (name,)).rowcount == 1
