"""clarity-server in-process: pairing, auth, the backup store and the CLI."""
import hashlib
import json
import sqlite3

import pytest
from fastapi.testclient import TestClient

from clarity_server import backups, cli, db, devices
from clarity_server.app import create_app


def sqlite_bytes(tmp_path, tag: str) -> bytes:
    p = tmp_path / f"{tag}.sqlite"
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE t (v TEXT)")
    c.execute("INSERT INTO t VALUES (?)", (tag,))
    c.commit()
    c.close()
    return p.read_bytes()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


@pytest.fixture
def env(tmp_path, monkeypatch):
    dbp, data = tmp_path / "clarity.db", tmp_path / "data"
    monkeypatch.setenv("CLARITY_DB", str(dbp))
    monkeypatch.setenv("CLARITY_DATA", str(data))
    return dbp, data


@pytest.fixture
def client(env):
    return TestClient(create_app(str(env[0]), str(env[1])))


def pair_code(capsys, name="phone") -> dict:
    assert cli.main(["device", "pair", name, "--json"]) == 0
    return json.loads(capsys.readouterr().out)


def paired(client, capsys, name="phone") -> str:
    r = client.post("/api/v1/pair", json={"code": pair_code(capsys, name)["code"], "name": name})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def auth(t):
    return {"Authorization": f"Bearer {t}"}


def test_health(client):
    r = client.get("/api/v1/health")
    assert r.status_code == 200 and r.json()["ok"] is True


def test_pair_code_shape(env, capsys):
    pc = pair_code(capsys)
    ws = pc["code"].split()
    assert len(ws) == 8 and all(w.islower() and w in devices.words() for w in ws)
    assert pc["link"] == "clarity://provision?code=" + "%20".join(ws)
    con = db.connect(str(env[0]))
    assert con.execute("SELECT code_sha256 FROM pair_codes").fetchone()[0] == devices.sha256(pc["code"])


def test_pair_once_any_case_and_hyphens(client, env, capsys):
    pc = pair_code(capsys)
    r = client.post("/api/v1/pair", json={"code": pc["code"].replace(" ", "-").upper(), "name": "x"})
    assert r.status_code == 200 and r.json()["device"] == "phone" and r.json()["scopes"] == ["backup"]
    tok = r.json()["token"]
    assert tok.encode() not in env[0].read_bytes()
    r = client.post("/api/v1/pair", json={"code": pc["code"], "name": "x"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "bad_code"


def test_expired_code(client, env, capsys):
    pc = pair_code(capsys)
    con = db.connect(str(env[0]))
    con.execute("UPDATE pair_codes SET expires = 0")
    assert client.post("/api/v1/pair", json={"code": pc["code"]}).status_code == 401


def test_auth_and_errors(client, capsys):
    assert client.get("/api/v1/backups").status_code == 401
    assert client.get("/api/v1/backups", headers=auth("nope")).json()["error"]["code"] == "bad_token"
    tok = paired(client, capsys)
    r = client.get("/api/v1/nonesuch", headers=auth(tok))
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"
    assert client.post("/api/v1/pair", json={}).status_code == 400


def test_lockout(client):
    for _ in range(devices.FAIL_LIMIT):
        client.get("/api/v1/backups", headers=auth("nope"))
    assert client.get("/api/v1/backups", headers=auth("nope")).json()["error"]["code"] == "locked_out"


def test_backups(client, env, capsys, tmp_path):
    tok = paired(client, capsys)
    a, b = sqlite_bytes(tmp_path, "a"), sqlite_bytes(tmp_path, "b")

    def up(raw, s):
        return client.post("/api/v1/backups", content=raw, headers={**auth(tok), "X-Content-Sha256": s,
                                                                      "Content-Type": "application/octet-stream"})
    assert up(b"not sqlite", sha(b"not sqlite")).json()["error"]["code"] == "not_sqlite"
    assert up(a, "0" * 64).json()["error"]["code"] == "sha_mismatch"
    r1 = up(a, sha(a)).json()
    assert r1["sha256"] == sha(a) and r1["bytes"] == len(a) and r1["device"] == "phone"
    assert up(a, sha(a)).json()["id"] == r1["id"]
    r2 = up(b, sha(b).upper()).json()
    assert r2["id"] != r1["id"]
    lst = client.get("/api/v1/backups", headers=auth(tok)).json()["backups"]
    assert [x["id"] for x in lst] == [r2["id"], r1["id"]]
    got = client.get(f"/api/v1/backups/{r1['id']}", headers=auth(tok))
    assert got.status_code == 200 and got.content == a
    assert got.headers["content-type"] == "application/octet-stream"
    assert client.get("/api/v1/backups/nope", headers=auth(tok)).status_code == 404
    files = sorted(p.name for p in (env[1] / "backups").iterdir())
    assert files == sorted([f"{sha(a)}.sqlite", f"{sha(b)}.sqlite"])


def test_too_large(client, capsys, monkeypatch, tmp_path):
    tok = paired(client, capsys)
    monkeypatch.setattr(backups, "MAX_BYTES", 100)
    raw = backups.SQLITE_MAGIC + b"x" * 200
    r = client.post("/api/v1/backups", content=raw, headers={**auth(tok), "X-Content-Sha256": sha(raw)})
    assert r.status_code == 413 and r.json()["error"]["code"] == "too_large"


def test_revoke_and_list(client, capsys):
    tok = paired(client, capsys)
    assert cli.main(["device", "list", "--json"]) == 0
    rows = json.loads(capsys.readouterr().out)
    assert [(d["name"], d["revoked"]) for d in rows] == [("phone", False)]
    assert cli.main(["device", "revoke", "phone"]) == 0
    assert client.get("/api/v1/backups", headers=auth(tok)).status_code == 401
    assert cli.main(["device", "revoke", "phone"]) == 1
