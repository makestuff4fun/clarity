"""The agent bridge (chat.py) against an in-memory fake den (httpx.MockTransport); never the real den."""
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from clarity_server import chat, cli
from clarity_server.app import create_app


class FakeDen:
    def __init__(self, token="den-tok"):
        self.token, self.down, self.msgs, self.idem, self.posts = token, False, [], {}, 0

    def reply(self, text):
        self.msgs.append({"id": len(self.msgs) + 1, "role": "agent", "text": text, "ts": 1.0})

    def __call__(self, req: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("down")
        if req.headers.get("authorization") != f"Bearer {self.token}":
            return httpx.Response(401, json={"error": {"code": "bad_token", "message": "no"}})
        if req.method == "POST":
            key = req.headers["idempotency-key"]
            if key not in self.idem:
                self.posts += 1
                body = req.content.decode()
                text = body.split('name="text"\r\n\r\n', 1)[1].rsplit("\r\n--", 1)[0]
                self.msgs.append({"id": len(self.msgs) + 1, "role": "user", "text": text, "ts": 1.0})
                self.idem[key] = self.msgs[-1]
            return httpx.Response(200, json=self.idem[key])
        after = int(req.url.params.get("after", 0))
        return httpx.Response(200, json={"messages": [m for m in self.msgs if m["id"] > after]})


@pytest.fixture
def setup(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("CLARITY_DB", str(tmp_path / "clarity.db"))
    monkeypatch.setenv("CLARITY_DATA", str(tmp_path / "data"))
    tf = tmp_path / "den.token"
    tf.write_text("den-tok\n")
    den = FakeDen()
    cfg = chat.Config(den_url="http://den.test", token_file=str(tf), session="S1", poll=3600)
    app = create_app(str(tmp_path / "clarity.db"), str(tmp_path / "data"), chat_cfg=cfg,
                     den_transport=httpx.MockTransport(den))
    c = TestClient(app)
    assert cli.main(["device", "pair", "phone", "--json"]) == 0
    code = json.loads(capsys.readouterr().out)["code"]
    tok = c.post("/api/v1/pair", json={"code": code, "name": "phone"}).json()["token"]
    return c, {"Authorization": f"Bearer {tok}"}, den, app.state.bridge, tf


def test_den_text():
    assert chat.den_text("chat", "hi", None) == "hi"
    assert chat.den_text("bug", "x", {"a": 1}) == '[bug] x\n\ncontext: {"a": 1}'


def test_unavailable_without_token_file(setup):
    c, h, den, bridge, tf = setup
    tf.write_text("")
    r = c.post("/api/v1/chat/messages", json={"text": "hi", "client_id": "c0", "kind": "chat"}, headers=h)
    assert r.status_code == 503 and r.json()["error"]["code"] == "chat_unavailable"


def test_validation_and_auth(setup):
    c, h, *_ = setup
    ok = {"text": "hi", "client_id": "c0", "kind": "chat"}
    assert c.post("/api/v1/chat/messages", json=ok).status_code == 401
    for bad in ({**ok, "kind": "rant"}, {**ok, "client_id": "bad id"}, {**ok, "text": ""}, {**ok, "text": "x" * 4001}):
        assert c.post("/api/v1/chat/messages", json=bad, headers=h).status_code == 400


def test_forward_once_retry_and_mirror(setup):
    c, h, den, bridge, _ = setup
    P = "/api/v1/chat/messages"
    m = c.post(P, json={"text": "Total wrong", "client_id": "b1", "kind": "bug", "context": {"screen": "home"}},
               headers=h).json()["message"]
    assert m["state"] == "pending" and m["role"] == "user" and m["kind"] == "bug"
    assert c.post(P, json={"text": "Total wrong", "client_id": "b1", "kind": "bug"}, headers=h).json()["message"]["id"] == m["id"]
    den.down = True
    c.post(P, json={"text": "CSV export", "client_id": "c1", "kind": "change"}, headers=h)
    bridge.tick()
    assert den.posts == 0
    den.down = False
    bridge.tick()
    bridge.tick()
    assert den.posts == 2
    assert [x["text"] for x in den.msgs] == ['[bug] Total wrong\n\ncontext: {"screen": "home"}', "[change] CSV export"]
    den.reply("Queued clarity/csv-export.")
    bridge.tick()
    bridge.tick()
    got = c.get(P + "?after=0", headers=h).json()["messages"]
    assert [(x["role"], x["state"]) for x in got] == [("user", "sent"), ("user", "sent"), ("agent", None)]
    assert got[2]["text"] == "Queued clarity/csv-export."
    assert [x["id"] for x in c.get(P + f"?after={got[0]['id']}", headers=h).json()["messages"]] == [got[1]["id"], got[2]["id"]]
