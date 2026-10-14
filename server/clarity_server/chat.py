"""The agent bridge: the app's bug reports, change requests and questions, bridged to den's
"Clarity" subject over loopback (the fleet standard: hanquest's course chat, Rebuild's trainer).

The app talks only to this server: a message is stored (pending), then one background thread
forwards pending messages oldest first to den's chat API with a den device token (scope chat,
read fresh from CLARITY_DEN_TOKEN_FILE; the app never holds it), and mirrors the subject's
replies (role agent) back exactly once, in den's order, with the cursor in the DB. Forwarding
and mirroring hold `io_lock` so they never interleave; no HTTP call to den is made while a DB
transaction is open.

Env: CLARITY_DEN_URL (default http://127.0.0.1:8781), CLARITY_DEN_TOKEN_FILE (default
~/.config/clarity/den.token), CLARITY_CHAT_SESSION (unset: chat answers 503),
CLARITY_BRIDGE_POLL (seconds, default 2)."""
import json
import os
import threading
import time
from pathlib import Path
from typing import Literal, Optional

import httpx
from pydantic import BaseModel, Field

from . import db

DEFAULT_DEN_URL = "http://127.0.0.1:8781"
DEFAULT_TOKEN_FILE = "~/.config/clarity/den.token"
MAX_TEXT = 4000
DEN_PAGE = 500
RETRY_STATUSES = {401, 403, 408, 429}   # den may get a new token or come back: keep pending

SCHEMA = """
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    ts REAL NOT NULL,
    client_id TEXT UNIQUE,
    kind TEXT NOT NULL,
    state TEXT,
    context TEXT,
    device TEXT,
    den_id INTEGER UNIQUE,
    error TEXT
);
CREATE TABLE IF NOT EXISTS chat_cursor (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    den_last_id INTEGER NOT NULL
);
INSERT OR IGNORE INTO chat_cursor (id, den_last_id) VALUES (1, 0);
"""


def migrate(con) -> None:
    con.executescript(SCHEMA)


class Config:
    def __init__(self, den_url=DEFAULT_DEN_URL, token_file=DEFAULT_TOKEN_FILE, session=None, poll=2.0):
        self.den_url = den_url.rstrip("/")
        self.token_file = token_file
        self.session = session or None
        self.poll = poll

    @classmethod
    def from_env(cls) -> "Config":
        e = os.environ
        return cls(den_url=e.get("CLARITY_DEN_URL") or DEFAULT_DEN_URL,
                   token_file=e.get("CLARITY_DEN_TOKEN_FILE") or DEFAULT_TOKEN_FILE,
                   session=e.get("CLARITY_CHAT_SESSION") or None,
                   poll=float(e.get("CLARITY_BRIDGE_POLL") or 2))

    def token(self) -> Optional[str]:
        """The den device token, read fresh each time; None if missing, unreadable or empty."""
        try:
            t = Path(os.path.expanduser(self.token_file)).read_text().strip()
        except (OSError, UnicodeDecodeError):
            return None
        return t or None

    def available(self) -> bool:
        return bool(self.session) and self.token() is not None


class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT)
    client_id: str = Field(pattern=r"^[A-Za-z0-9._-]{1,64}$")
    kind: Literal["bug", "change", "chat"]
    context: Optional[dict] = None


def den_text(kind: str, text: str, context) -> str:
    out = text if kind == "chat" else f"[{kind}] {text}"
    if context is not None:
        out += "\n\ncontext: " + json.dumps(context)
    return out


def as_message(r) -> dict:
    return {"id": r["id"], "role": r["role"], "text": r["text"], "ts": r["ts"], "client_id": r["client_id"],
            "kind": r["kind"], "state": r["state"],
            "context": json.loads(r["context"]) if r["context"] is not None else None}


class Bridge:
    def __init__(self, db_path: str, cfg: Config, clock=time.time, transport: httpx.BaseTransport | None = None):
        self.db_path, self.cfg, self.clock, self.transport = db_path, cfg, clock, transport
        self.io_lock = threading.Lock()     # forwarding and mirroring never interleave
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None

    def _con(self):
        return db.connect(self.db_path)

    def client(self) -> httpx.Client:
        return httpx.Client(base_url=self.cfg.den_url, timeout=10, trust_env=False, transport=self.transport)

    # --- the store ----------------------------------------------------------------------------
    def store(self, body: MessageIn, device: str) -> tuple[dict, bool]:
        """(message, new). The same client_id again returns the stored message."""
        con = self._con()
        try:
            cur = con.execute(
                "INSERT OR IGNORE INTO chat_messages (role, text, ts, client_id, kind, state, context, device)"
                " VALUES ('user', ?, ?, ?, ?, 'pending', ?, ?)",
                (body.text, self.clock(), body.client_id, body.kind,
                 None if body.context is None else json.dumps(body.context, ensure_ascii=False), device))
            r = con.execute("SELECT * FROM chat_messages WHERE client_id = ?", (body.client_id,)).fetchone()
            return as_message(r), cur.rowcount == 1
        finally:
            con.close()

    def list(self, after: Optional[int], limit: int) -> list[dict]:
        con = self._con()
        try:
            if after is not None:
                rows = con.execute("SELECT * FROM chat_messages WHERE id > ? ORDER BY id LIMIT ?",
                                   (after, limit)).fetchall()
            else:
                rows = con.execute("SELECT * FROM chat_messages ORDER BY id DESC LIMIT ?", (limit,)).fetchall()[::-1]
        finally:
            con.close()
        return [as_message(r) for r in rows]

    # --- forwarding ---------------------------------------------------------------------------
    def flush(self) -> None:
        """Forward pending messages, oldest first; stop at the first one den could not take now."""
        if not self.cfg.available():
            return
        with self.io_lock:
            con = self._con()
            try:
                pending = [r["id"] for r in con.execute(
                    "SELECT id FROM chat_messages WHERE state = 'pending' ORDER BY id").fetchall()]
            finally:
                con.close()
            if not pending:
                return
            with self.client() as http:
                for mid in pending:
                    if not self._forward(http, mid):
                        break

    def _forward(self, http: httpx.Client, mid: int) -> bool:
        """True when the message is settled (sent or failed); False to retry later."""
        token = self.cfg.token()
        if token is None:
            return False
        con = self._con()
        try:
            r = con.execute("SELECT * FROM chat_messages WHERE id = ?", (mid,)).fetchone()
        finally:
            con.close()
        if r is None or r["state"] != "pending":
            return True
        ctx = json.loads(r["context"]) if r["context"] is not None else None
        try:
            resp = http.post(f"/api/v1/chat/{self.cfg.session}",
                             files={"text": (None, den_text(r["kind"], r["text"], ctx).encode())},
                             headers={"Authorization": f"Bearer {token}", "Idempotency-Key": r["client_id"]})
        except httpx.HTTPError:
            return False
        if resp.status_code >= 500 or resp.status_code in RETRY_STATUSES:
            return False
        con = self._con()
        try:
            if resp.status_code == 200:
                try:
                    den_id = resp.json().get("id")
                except (ValueError, AttributeError):
                    den_id = None
                con.execute("UPDATE chat_messages SET state = 'sent', den_id = ?, error = NULL WHERE id = ?",
                            (den_id if isinstance(den_id, int) else None, mid))
            else:
                con.execute("UPDATE chat_messages SET state = 'failed', error = ? WHERE id = ?",
                            (f"den {resp.status_code}: {resp.text[:500]}", mid))
        finally:
            con.close()
        return True

    # --- mirroring ----------------------------------------------------------------------------
    def mirror(self) -> None:
        if not self.cfg.available():
            return
        token = self.cfg.token()
        with self.io_lock, self.client() as http:
            while True:
                con = self._con()
                try:
                    cursor = con.execute("SELECT den_last_id FROM chat_cursor WHERE id = 1").fetchone()["den_last_id"]
                finally:
                    con.close()
                try:
                    resp = http.get(f"/api/v1/chat/{self.cfg.session}", params={"after": cursor, "limit": DEN_PAGE},
                                    headers={"Authorization": f"Bearer {token}"})
                except httpx.HTTPError:
                    return
                if resp.status_code != 200:
                    return
                try:
                    msgs = resp.json().get("messages") or []
                except (ValueError, AttributeError):
                    return
                for m in msgs:
                    if isinstance(m, dict):
                        self._mirror_one(m)
                if len(msgs) < DEN_PAGE:
                    return

    def _mirror_one(self, m: dict) -> None:
        den_id = m.get("id")
        if not isinstance(den_id, int):
            return
        con = self._con()
        try:
            con.execute("BEGIN IMMEDIATE")
            try:
                last = con.execute("SELECT den_last_id FROM chat_cursor WHERE id = 1").fetchone()["den_last_id"]
                if den_id <= last:
                    con.execute("COMMIT")
                    return
                if m.get("role") == "agent":
                    ts = m.get("ts") if isinstance(m.get("ts"), (int, float)) else self.clock()
                    con.execute("INSERT OR IGNORE INTO chat_messages (role, text, ts, kind, state, den_id)"
                                " VALUES ('agent', ?, ?, 'chat', NULL, ?)", (m.get("text") or "", ts, den_id))
                con.execute("UPDATE chat_cursor SET den_last_id = ? WHERE id = 1", (den_id,))
                con.execute("COMMIT")
            except BaseException:
                con.execute("ROLLBACK")
                raise
        finally:
            con.close()

    # --- the background thread ----------------------------------------------------------------
    def tick(self) -> None:
        self.flush()
        self.mirror()

    def wake(self) -> None:
        self._wake.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.tick()
            except Exception:       # keep the bridge alive; the next poll retries
                pass
            self._wake.wait(self.cfg.poll)
            self._wake.clear()

    def start(self) -> None:
        if self._thread is None:
            self._stop.clear()
            self._thread = threading.Thread(target=self._run, name="clarity-chat-bridge", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(15)
            self._thread = None
