"""Acceptance: clarity/server-chat (clarity-server 3: the agent bridge to den). PROTECTED (.den/**).

Brian, 2026-10-14: "Since it's a standard for our apps, add the agent button to directly add bug
reports and queue changes." The fleet standard (hanquest backend/knowledge/course_chat.py,
gym-app rebuild_server/trainer.py): the app talks ONLY to its own red server; the server stores
the message, forwards it to a den subject over loopback with a den device token (scope chat)
read from a file, and mirrors den's replies back. The app never holds a den token.
fake_den.py stands in for den.

    server/.venv/bin/python .den/checks/check_server_chat.py
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from server_common import CHK, PY, Server, error_shape, free_port, http, need, need_server_package, run_server_bin_check, tmpdir  # noqa: E402

need_server_package()
run_server_bin_check()

home = tmpdir()
tokfile = home / "den.token"
tokfile.write_text("den-chat-token-" + "z" * 40 + "\n")
dport = free_port()
den = subprocess.Popen([PY, str(CHK / "fake_den.py"), str(dport), str(tokfile)], stdout=subprocess.PIPE, text=True)
need(den.stdout.readline().strip() == "ready", "fake den did not start")
DEN = f"http://127.0.0.1:{dport}"
T = tokfile.read_text().strip()
st, sub = http("POST", DEN + "/api/v1/subjects", {"name": "Clarity", "project": "clarity"}, token=T)
need(st == 200, f"fake den subject: {st} {sub}")
S = sub["session"]


def den_msgs():
    return http("GET", DEN + "/_fake/state")[1]["messages"][S]


def wait(pred, secs=15):
    end = time.time() + secs
    while time.time() < end:
        v = pred()
        if v:
            return v
        time.sleep(0.25)
    return None


try:
    # not configured: no session -> 503 in the error shape
    with Server(home / "a", extra_env={"CLARITY_DEN_URL": DEN, "CLARITY_DEN_TOKEN_FILE": str(tokfile)}) as s:
        tok = s.pair()
        st, b = http("POST", s.base + "/api/v1/chat/messages", {"text": "hi", "client_id": "c0", "kind": "chat"}, token=tok)
        need(st == 503 and error_shape(b), f"with no CLARITY_CHAT_SESSION the chat must answer 503, got {st} {b}")

    env = {"CLARITY_DEN_URL": DEN, "CLARITY_DEN_TOKEN_FILE": str(tokfile), "CLARITY_CHAT_SESSION": S, "CLARITY_BRIDGE_POLL": "0.5"}
    with Server(home / "b", extra_env=env) as s:
        st, b = http("POST", s.base + "/api/v1/chat/messages", {"text": "hi", "client_id": "c0", "kind": "chat"})
        need(st == 401, f"chat without a device token must be 401, got {st}")
        tok = s.pair()
        P = s.base + "/api/v1/chat/messages"
        st, b = http("POST", P, {"text": "x", "client_id": "bad id!", "kind": "chat"}, token=tok)
        need(st == 400, f"a bad client_id must be 400, got {st}")
        st, b = http("POST", P, {"text": "x", "client_id": "c1", "kind": "rant"}, token=tok)
        need(st == 400, f"kind must be one of bug, change, chat; 'rant' got {st}")
        ctx = {"screen": "home", "app_version": "5.4.4"}
        st, m1 = http("POST", P, {"text": "The total on Home is wrong after a transfer", "client_id": "c-bug-1",
                                  "kind": "bug", "context": ctx}, token=tok)
        need(st == 200 and isinstance(m1, dict) and isinstance(m1.get("message"), dict), f"POST chat -> {st} {m1}")
        m1 = m1["message"]
        need({"id", "role", "text", "ts", "client_id", "kind", "state", "context"} <= set(m1) and m1["role"] == "user"
             and m1["kind"] == "bug" and m1["client_id"] == "c-bug-1", f"a Message needs id, role user, text, ts, client_id, kind, state, context: {m1}")
        st, again = http("POST", P, {"text": "The total on Home is wrong after a transfer", "client_id": "c-bug-1",
                                     "kind": "bug", "context": ctx}, token=tok)
        need(st == 200 and again["message"]["id"] == m1["id"], "the same client_id twice must be stored once")
        got = wait(lambda: [m for m in den_msgs() if "Home is wrong" in m["text"]])
        need(got and len(got) == 1, f"the bug report must reach den exactly once, got {got}")
        need(got[0]["text"].startswith("[bug]") and '"screen": "home"' in got[0]["text"].replace('":"', '": "'),
             f"den must see '[bug] <text>' plus the context JSON, got {got[0]['text']!r}")
        calls = http("GET", DEN + "/_fake/calls")[1]
        need(all(c["auth_ok"] for c in calls if c["path"].startswith(f"/api/v1/chat/{S}")),
             "every call to den must carry the den token from CLARITY_DEN_TOKEN_FILE")

        # den is down: the change request waits, then goes exactly once
        http("POST", DEN + "/_fake/down", {"down": True})
        st, m2 = http("POST", P, {"text": "Add a monthly CSV export", "client_id": "c-chg-1", "kind": "change"}, token=tok)
        need(st == 200 and m2["message"]["state"] in ("pending", "failed"), f"with den down the message is kept pending: {st} {m2}")
        time.sleep(2)
        http("POST", DEN + "/_fake/down", {"down": False})
        got = wait(lambda: [m for m in den_msgs() if "monthly CSV" in m["text"]])
        need(got and len(got) == 1 and got[0]["text"].startswith("[change]"), f"the queued change must reach den once after it is back: {got}")
        time.sleep(2)
        need(len([m for m in den_msgs() if "monthly CSV" in m["text"]]) == 1, "the change was forwarded twice")

        # the agent answers in den: mirrored once, in order, as role agent
        http("POST", DEN + "/_fake/reply", {"session": S, "text": "Queued clarity/csv-export."})
        def agent():
            st, b = http("GET", P + "?after=0&limit=50", token=tok)
            return [m for m in b["messages"] if m["role"] == "agent"] if st == 200 else None
        a = wait(agent)
        need(a and len(a) == 1 and a[0]["text"] == "Queued clarity/csv-export.", f"den's reply must be mirrored once as role agent: {a}")
        time.sleep(1.5)
        st, b = http("GET", P + "?after=0&limit=50", token=tok)
        ids = [m["id"] for m in b["messages"]]
        need(ids == sorted(ids) and len(ids) == 3, f"the thread must be 3 messages oldest first (bug, change, reply), got {b['messages']}")
        st, b2 = http("GET", P + f"?after={ids[0]}&limit=50", token=tok)
        need([m["id"] for m in b2["messages"]] == ids[1:], "?after=<id> must return only newer messages")
    print("server-chat OK")
finally:
    den.terminate()
