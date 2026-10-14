"""clarity-server's HTTP API, all under /api/v1.

Every route except health and pair needs `Authorization: Bearer <token>`. Errors are
{"error": {"code", "message"}}: 400 bad input, 401 no, bad or revoked token (or a
locked-out IP), 403 missing scope, 404 unknown thing, 409 wrong state, 413 too large,
503 chat not configured (no CLARITY_CHAT_SESSION or den token file).
"""
import os
import re
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import VERSION, backups, chat, db, devices
from .errors import ApiError

_HTTP_CODES = {400: "bad_input", 401: "unauthorized", 403: "forbidden", 404: "not_found",
               405: "method_not_allowed", 409: "wrong_state", 413: "too_large"}


class PairIn(BaseModel):
    code: str
    name: str = ""
    platform: str = ""
    app_version: str = ""


def default_db() -> str:
    return os.environ.get("CLARITY_DB") or str(Path.home() / ".local" / "share" / "clarity" / "clarity.db")


def default_data() -> str:
    return os.environ.get("CLARITY_DATA") or str(Path.home() / ".local" / "share" / "clarity" / "data")


def create_app(db_path: str, data_dir: str, *, clock=time.time, chat_cfg: chat.Config | None = None,
               den_transport=None) -> FastAPI:
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    db.init(db_path)
    lockout = devices.Lockout()
    bridge = chat.Bridge(db_path, chat_cfg or chat.Config(), clock, den_transport)

    @asynccontextmanager
    async def lifespan(app):
        bridge.start()
        try:
            yield
        finally:
            bridge.stop()

    app = FastAPI(title="clarity-server", version=VERSION, docs_url=None, redoc_url=None, openapi_url=None,
                  lifespan=lifespan)
    app.state.bridge = bridge

    def err(status: int, code: str, message: str) -> JSONResponse:
        return JSONResponse(ApiError(status, code, message).body(), status_code=status)

    @app.exception_handler(ApiError)
    async def _api_error(request, e: ApiError):
        return JSONResponse(e.body(), status_code=e.status)

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request, e: StarletteHTTPException):
        return err(e.status_code, _HTTP_CODES.get(e.status_code, "error"), str(e.detail))

    @app.exception_handler(RequestValidationError)
    async def _bad_input(request, e: RequestValidationError):
        first = e.errors()[0] if e.errors() else {}
        where = ".".join(str(x) for x in first.get("loc", ()) if x != "body")
        return err(400, "bad_input", f"{where}: {first.get('msg', 'invalid request')}".lstrip(": "))

    def ip_of(request: Request) -> str:
        return devices.client_ip(request.client.host if request.client else "", request.headers.get("x-forwarded-for"))

    def need(scope: str | None):
        """A dependency: the authenticated device, holding `scope` (None: any valid token)."""
        def dep(request: Request) -> dict:
            ip, now = ip_of(request), clock()
            if lockout.locked(ip, now):
                raise ApiError(401, "locked_out", "too many failed attempts; try again later")
            m = re.fullmatch(r"Bearer\s+(\S+)", request.headers.get("authorization", "").strip(), re.I)
            if not m:
                raise ApiError(401, "no_token", "an Authorization: Bearer token is required")
            con = db.connect(db_path)
            try:
                dev = devices.authenticate(con, m.group(1), ip, now)
            finally:
                con.close()
            if dev is None:
                lockout.fail(ip, now)
                raise ApiError(401, "bad_token", "the token is wrong or revoked")
            if scope and scope not in dev["scopes"]:
                raise ApiError(403, "missing_scope", f"this device lacks the {scope} scope")
            return dev
        return dep

    @app.get("/api/v1/health")
    def health():
        return {"ok": True, "version": VERSION}

    @app.post("/api/v1/pair")
    def pair(body: PairIn, request: Request):
        ip = ip_of(request)
        if lockout.locked(ip, clock()):
            raise ApiError(401, "locked_out", "too many failed attempts; try again later")
        con = db.connect(db_path)
        try:
            return devices.redeem(con, body.code, body.platform, body.app_version, clock())
        except ApiError as e:
            if e.status == 401:
                lockout.fail(ip, clock())
            raise
        finally:
            con.close()

    # --- backups: whole SQLite files from the phone, never deleted here ---------------------
    @app.post("/api/v1/backups")
    async def upload_backup(request: Request, dev: dict = Depends(need("backup"))):
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > backups.MAX_BYTES:
            raise ApiError(413, "too_large", f"a backup may be at most {backups.MAX_BYTES} bytes")
        buf = bytearray()
        async for chunk in request.stream():
            buf += chunk
            if len(buf) > backups.MAX_BYTES:
                raise ApiError(413, "too_large", f"a backup may be at most {backups.MAX_BYTES} bytes")

        def act():
            con = db.connect(db_path)
            try:
                return backups.store(con, data_dir, bytes(buf), request.headers.get("x-content-sha256", ""),
                                     dev["name"], clock())
            finally:
                con.close()
        return await run_in_threadpool(act)

    @app.get("/api/v1/backups")
    def list_backups(dev: dict = Depends(need("backup"))):
        con = db.connect(db_path)
        try:
            return {"backups": backups.listing(con)}
        finally:
            con.close()

    @app.get("/api/v1/backups/{backup_id}")
    def get_backup(backup_id: str, dev: dict = Depends(need("backup"))):
        con = db.connect(db_path)
        try:
            p = backups.path_of(con, data_dir, backup_id)
        finally:
            con.close()
        return FileResponse(p, media_type="application/octet-stream")

    # --- chat: bug reports, change requests and questions, bridged to den (chat.py) ---------
    @app.post("/api/v1/chat/messages")
    def post_chat(body: chat.MessageIn, dev: dict = Depends(need(None))):
        if not body.text.strip():
            raise ApiError(400, "bad_input", "text: the message is empty")
        if not bridge.cfg.available():
            raise ApiError(503, "chat_unavailable", "the agent chat is not available (no den session or token)")
        msg, new = bridge.store(body, dev["name"])
        if new:
            bridge.wake()
        return {"message": msg}

    @app.get("/api/v1/chat/messages")
    def get_chat(after: int | None = Query(None, ge=0), limit: int = Query(100, ge=1, le=500),
                 dev: dict = Depends(need(None))):
        return {"messages": bridge.list(after, limit)}

    return app


def app_from_env() -> FastAPI:
    """uvicorn --factory clarity_server.app:app_from_env. CLARITY_DB, CLARITY_DATA, CLARITY_DEN_URL,
    CLARITY_DEN_TOKEN_FILE, CLARITY_CHAT_SESSION, CLARITY_BRIDGE_POLL."""
    return create_app(default_db(), default_data(), chat_cfg=chat.Config.from_env())
