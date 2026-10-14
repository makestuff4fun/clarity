"""A stand-in for den serve's chat and subjects API (copied from gym-app's fake_den.py). PROTECTED (.den/**).

rebuild-server's trainer bridge talks to den over loopback with a den device token (scope
chat). This fake answers the routes the bridge uses with the shapes den-fleet's
schema/api-v1.json gives them, records every call, and lets a check play the trainer:

    server/.venv/bin/python .den/checks/fake_den.py PORT TOKEN_FILE [--no-role]

den routes (Authorization: Bearer <the token in TOKEN_FILE>, else 401):
    GET  /api/v1/health
    POST /api/v1/subjects          {name, project?, model?, role?} -> Subject (role echoed,
                                   unless --no-role: a den without subjects-role ignores it)
    GET  /api/v1/chats             [{session, ..., subject: Subject}]
    POST /api/v1/subject/{s}       {model?|name?|archived?|role?} -> Subject
    POST /api/v1/chat/{s}          multipart/form-data: text, image* -> the stored message;
                                   Idempotency-Key replays the first response
    GET  /api/v1/chat/{s}?after=&limit=   {session, messages: [oldest first]}
    GET  /api/v1/media/{id}        the bytes
    POST /api/v1/crash             a CrashReport (den_crash_report.schema.json) -> {id, duplicate, top_frame};
                                   a known report_id -> duplicate; over 256 KB -> 413; invalid -> 400
                                   (den accepts scope read OR chat; here: the one token)
control (no auth; only the check calls these):
    POST /_fake/reply   {session, text, images?: [base64 png], sender?, role?}  a message den stored
                        (role "agent" by default, sender = the session; role "user": typed elsewhere)
    POST /_fake/busy    {session, busy: bool}
    POST /_fake/down    {down: bool}   while down every /api/v1 request gets its connection dropped
    POST /_fake/crash_status {status: int|null}   answer POST /api/v1/crash with this status (null: normal)
    GET  /_fake/calls   every /api/v1 call: {method, path, idem, auth_ok, json?, text?, images?: [{sha256, mime}]}
    GET  /_fake/state   {subjects: {...}, messages: {session: [...]}}
"""
import base64
import hashlib
import json
import re
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT, TOKEN = int(sys.argv[1]), open(sys.argv[2]).read().strip()
NO_ROLE = "--no-role" in sys.argv[3:]
LOCK = threading.Lock()
SUBJECTS: dict = {}          # session -> Subject
MESSAGES: dict = {}          # session -> [message]
MEDIA: dict = {}             # id -> (mime, bytes)
IDEM: dict = {}              # (path, key) -> (status, body)
CALLS: list = []
STATE = {"down": False, "next_id": 1, "crash_status": None}
CRASHES: dict = {}           # report_id -> {"id", "report"}
CRASH_SCHEMA = None          # den's CrashReport, loaded lazily from den_crash_report.schema.json
CRASH_MAX = 262144


def crash(js):
    global CRASH_SCHEMA
    if STATE["crash_status"]:
        st = STATE["crash_status"]
        return st, {"error": {"code": "forced", "message": f"fake den answers {st}"}}
    import jsonschema
    from pathlib import Path
    if CRASH_SCHEMA is None:
        CRASH_SCHEMA = json.loads((Path(__file__).parent / "den_crash_report.schema.json").read_text())
    errs = list(jsonschema.Draft202012Validator(CRASH_SCHEMA).iter_errors(js)) if isinstance(js, dict) else ["not an object"]
    if errs:
        return 400, {"error": {"code": "bad_report", "message": str(getattr(errs[0], "message", errs[0]))[:300]}}
    rid = js["report_id"]
    if rid in CRASHES:
        return 200, {"id": CRASHES[rid]["id"], "duplicate": True, "top_frame": None}
    CRASHES[rid] = {"id": len(CRASHES) + 1, "report": js}
    frames = [ln.strip()[3:] for ln in js["stack"].splitlines() if ln.strip().startswith("at ")]
    top = next((f for f in frames if f.startswith(js["app"])), frames[0] if frames else None)
    return 200, {"id": CRASHES[rid]["id"], "duplicate": False, "top_frame": top}


def sniff(b: bytes):
    if b.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if b.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "image/webp"
    return None


def parse_multipart(body: bytes, ctype: str):
    m = re.search(r'boundary="?([^";]+)"?', ctype or "")
    if not m:
        raise ValueError("no multipart boundary")
    fields, files = {}, []
    for part in body.split(b"--" + m.group(1).encode())[1:]:
        if part.startswith(b"--"):
            break
        head, _, data = part.lstrip(b"\r\n").partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        disp = next((ln for ln in head.decode("utf-8", "replace").split("\r\n")
                     if ln.lower().startswith("content-disposition")), "")
        name = re.search(r'name="([^"]*)"', disp)
        fn = re.search(r'filename="([^"]*)"', disp)
        if not name:
            continue
        if fn is not None:
            files.append((name.group(1), fn.group(1), data))
        else:
            fields[name.group(1)] = data.decode("utf-8")
    return fields, files


def subject(name, project, model, role):
    s = f"s-{re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')[:40]}-{secrets.token_hex(3)}"
    sub = {"session": s, "name": name, "project": project, "model": model or "sonnet", "archived": False,
           "created": time.time(), "busy": False, "context_tokens": None, "tasks": []}
    if not NO_ROLE:
        sub["role"] = role
    return sub


def add_message(session, role, sender, text, images):
    ts = time.time()
    media = []
    for i, data in enumerate(images):
        mid = hashlib.sha256(data).hexdigest()[:24] + f"-{STATE['next_id']}-{i}"
        MEDIA[mid] = (sniff(data) or "application/octet-stream", data)
        media.append({"id": mid, "mime": MEDIA[mid][0], "bytes": len(data), "name": f"{i}.png",
                      "url": f"/api/v1/media/{mid}"})
    msg = {"id": STATE["next_id"], "session": session, "role": role, "sender": sender, "text": text, "ts": ts,
           "delivered_ts": None, "media": media}
    STATE["next_id"] += 1
    MESSAGES.setdefault(session, []).append(msg)
    return msg


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def err(self, code, ecode, msg):
        self.send(code, {"error": {"code": ecode, "message": msg}})

    def body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def drop(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.close_connection = True

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        u = urlparse(self.path)
        raw = self.body() if method == "POST" else b""
        if u.path.startswith("/_fake/"):
            return self.control(method, u.path, raw)
        if not u.path.startswith("/api/v1/"):
            return self.err(404, "not_found", u.path)
        with LOCK:
            down = STATE["down"]
        if down:
            return self.drop()
        auth_ok = self.headers.get("Authorization", "") == f"Bearer {TOKEN}"
        call = {"method": method, "path": u.path, "query": u.query, "idem": self.headers.get("Idempotency-Key"),
                "auth_ok": auth_ok, "ts": time.time()}
        ctype = self.headers.get("Content-Type", "")
        if raw and ctype.startswith("application/json"):
            try:
                call["json"] = json.loads(raw)
            except ValueError:
                call["json"] = None
        fields, files = {}, []
        if raw and ctype.startswith("multipart/form-data"):
            try:
                fields, files = parse_multipart(raw, ctype)
            except ValueError as e:
                with LOCK:
                    CALLS.append(call)
                return self.err(400, "bad_multipart", str(e))
            call["text"] = fields.get("text")
            call["images"] = [{"sha256": hashlib.sha256(d).hexdigest(), "mime": sniff(d)} for _, _, d in files]
        with LOCK:
            CALLS.append(call)
        if u.path == "/api/v1/health":
            return self.send(200, {"ok": True})
        if not auth_ok:
            return self.err(401, "bad_token", "the token is wrong or revoked")
        if u.path == "/api/v1/crash" and len(raw) > CRASH_MAX:
            return self.err(413, "too_large", "crash report over 256 KB")
        q = parse_qs(u.query)
        with LOCK:
            # crash reports dedupe by report_id (as den does), never by Idempotency-Key
            key = (u.path, call["idem"]) if method == "POST" and call["idem"] and u.path != "/api/v1/crash" else None
            if key and key in IDEM:
                return self.send(*IDEM[key])
            status, out = self.api(method, u.path, q, call.get("json"), fields, files)
            if key:
                IDEM[key] = (status, out)
        if isinstance(out, tuple):
            return self.send(status, raw=out[1], ctype=out[0])
        return self.send(status, out)

    def api(self, method, path, q, js, fields, files):
        m = re.fullmatch(r"/api/v1/chat/([^/]+)", path)
        if method == "POST" and path == "/api/v1/crash":
            return crash(js)
        if method == "POST" and path == "/api/v1/subjects":
            js = js or {}
            if not isinstance(js.get("name"), str) or not js["name"].strip():
                return 400, {"error": {"code": "bad_name", "message": "name"}}
            sub = subject(js["name"], js.get("project"), js.get("model"), js.get("role"))
            SUBJECTS[sub["session"]] = sub
            MESSAGES[sub["session"]] = []
            return 200, sub
        if method == "GET" and path == "/api/v1/chats":
            out = []
            for s, sub in SUBJECTS.items():
                msgs = MESSAGES.get(s) or []
                out.append({"session": s, "online": True, "last_poll": None, "registered": sub["created"],
                            "undelivered": 0, "last_message": msgs[-1] if msgs else None, "subject": dict(sub)})
            return 200, out
        sm = re.fullmatch(r"/api/v1/subject/([^/]+)", path)
        if method == "POST" and sm:
            sub = SUBJECTS.get(sm.group(1))
            if sub is None:
                return 404, {"error": {"code": "no_subject", "message": "no subject"}}
            js = js or {}
            if "model" in js:
                if js["model"] not in ("sonnet", "opus"):
                    return 400, {"error": {"code": "bad_model", "message": "model"}}
                sub["model"] = js["model"]
            for k in ("name", "archived") + (() if NO_ROLE else ("role",)):
                if k in js:
                    sub[k] = js[k]
            return 200, dict(sub)
        if m and method == "POST":
            s = m.group(1)
            if s not in SUBJECTS:
                return 404, {"error": {"code": "no_session", "message": "no chat session"}}
            text = fields.get("text") or ""
            imgs = [d for name, _, d in files if name == "image"]
            if not text.strip() and not imgs:
                return 400, {"error": {"code": "empty_message", "message": "a message needs text or an image"}}
            if any(sniff(d) is None for d in imgs):
                return 415, {"error": {"code": "unsupported_media", "message": "images only"}}
            return 200, add_message(s, "user", "clarity-app", text, imgs)
        if m and method == "GET":
            s = m.group(1)
            if s not in SUBJECTS:
                return 404, {"error": {"code": "no_session", "message": "no chat session"}}
            limit = max(1, min(int((q.get("limit") or ["50"])[0]), 500))
            msgs = MESSAGES.get(s) or []
            if "after" in q:
                a = int(q["after"][0])
                msgs = [x for x in msgs if x["id"] > a][:limit]
            else:
                msgs = msgs[-limit:]
            return 200, {"session": s, "messages": msgs}
        mm = re.fullmatch(r"/api/v1/media/([^/]+)", path)
        if method == "GET" and mm:
            if mm.group(1) not in MEDIA:
                return 404, {"error": {"code": "no_media", "message": "no such media"}}
            return 200, MEDIA[mm.group(1)]
        return 404, {"error": {"code": "not_found", "message": f"fake den has no {method} {path}"}}

    def control(self, method, path, raw):
        js = json.loads(raw) if raw else {}
        with LOCK:
            if path == "/_fake/reply" and method == "POST":
                s = js["session"]
                if s not in SUBJECTS:
                    return self.err(404, "no_session", s)
                imgs = [base64.b64decode(x) for x in js.get("images") or []]
                role = js.get("role") or "agent"
                sender = js.get("sender") or (s if role == "agent" else "den-phone")
                msg = add_message(s, role, sender, js.get("text") or "", imgs)
                return self.send(200, msg)
            if path == "/_fake/busy" and method == "POST":
                SUBJECTS[js["session"]]["busy"] = bool(js["busy"])
                return self.send(200, {"ok": True})
            if path == "/_fake/down" and method == "POST":
                STATE["down"] = bool(js.get("down"))
                return self.send(200, {"ok": True})
            if path == "/_fake/crash_status" and method == "POST":
                STATE["crash_status"] = js.get("status")
                return self.send(200, {"ok": True})
            if path == "/_fake/calls":
                return self.send(200, CALLS)
            if path == "/_fake/state":
                return self.send(200, {"subjects": SUBJECTS, "messages": MESSAGES, "crashes": CRASHES})
        return self.err(404, "not_found", path)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    srv = Server(("127.0.0.1", PORT), H)
    print("ready", flush=True)
    srv.serve_forever()
