"""SQLite: one connection per use (FastAPI runs sync routes in a threadpool), WAL.

Later features (server-backup, server-chat) add their tables with their own migrate(con),
called from init()."""
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS pair_codes (
    code_sha256 TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    scopes TEXT NOT NULL,
    created REAL NOT NULL,
    expires REAL NOT NULL,
    used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS devices (
    name TEXT PRIMARY KEY,
    token_sha256 TEXT NOT NULL UNIQUE,
    scopes TEXT NOT NULL,
    created REAL NOT NULL,
    last_seen REAL,
    last_ip TEXT,
    platform TEXT,
    app_version TEXT,
    revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS backups (
    id TEXT PRIMARY KEY,
    sha256 TEXT NOT NULL UNIQUE,
    bytes INTEGER NOT NULL,
    ts REAL NOT NULL,
    device TEXT NOT NULL
);
"""


def connect(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(path, timeout=30, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=30000")
    return con


def init(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    con = connect(path)
    try:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(SCHEMA)
        from . import chat
        chat.migrate(con)
    finally:
        con.close()
