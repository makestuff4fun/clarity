"""Acceptance: clarity/money-summary. PROTECTED (.den/**).

Brian, 2026-11-11 (den-app ROADMAP "Expenses", DECIDED): his daily expenses move to Clarity, and a job
on red may read its backups. From the NEWEST stored backup, `bin/clarity money ...` makes
  1. `money summary`: one small JSON summary of the month so far (the source of den-app's Money card);
  2. `money csv`: a month's transactions as the CSV he files with each invoice.
Writing the summary into den's records store is NOT part of this task: the summary is built by
money.summarize() and written only by money.write_summary(), the seam where that put goes later.

Hermetic: temp DB + data dir, the real server under uvicorn for uploads (as the server checks do),
fixtures from money_fixtures.py (invented rows in the real v48 schema). No Flutter, no network.
    server/.venv/bin/python .den/checks/check_money_summary.py
"""
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import time
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from server_common import CLARITY, ROOT, SERVER, Server, fail, http, need, run_server_bin_check, sha, tmpdir  # noqa: E402
import money_fixtures as F  # noqa: E402

SHANGHAI = {"TZ": "Asia/Shanghai"}
EPS = 0.005


def clarity(home, *args, env=None):
    e = {**os.environ, "CLARITY_DB": str(home / "clarity.db"), "CLARITY_DATA": str(home / "data"),
         "PYTHONPATH": str(SERVER), **SHANGHAI, **(env or {})}
    return subprocess.run([CLARITY, *args], cwd=ROOT, env=e, capture_output=True, text=True, timeout=120)


def show(r):
    return f"rc {r.returncode}\nstdout: {r.stdout[-1500:]}\nstderr: {r.stderr[-1500:]}"


# ---- step 1 (cheap, no server): the subcommands exist -----------------------------------------
for sub in ("summary", "csv"):
    r = subprocess.run([CLARITY, "money", sub, "--help"], cwd=ROOT, capture_output=True, text=True, timeout=60)
    need(r.returncode == 0, f"step 1: `bin/clarity money {sub} --help` must exist and exit 0:\n{show(r)}")
    for opt in ("--device", "--today", "--out") + (("--month",) if sub == "csv" else ()):
        need(opt in r.stdout, f"step 1: `bin/clarity money {sub}` must take {opt}")
print("step 1: bin/clarity money summary|csv exist: ok")

# ---- step 2: the server's own suite stays green ------------------------------------------------
run_server_bin_check()

# ---- step 3: fixtures, uploaded through the real server ----------------------------------------
fx = F.build_all(tmpdir("clarity-money-fx-"))
home = tmpdir("clarity-money-")
with Server(home) as s:
    tok_a = s.pair("find-n6")
    tok_b = s.pair("old-phone")
    ids = {}
    for name, tok in (("older", tok_a), ("main", tok_a), ("empty", tok_b)):   # upload order = ts order
        raw = fx[name].read_bytes()
        st, b = http("POST", s.base + "/api/v1/backups", token=tok, raw=raw, headers={"X-Content-Sha256": sha(raw)})
        need(st == 200 and isinstance(b, dict), f"upload of fixture {name} failed: {st} {b}")
        ids[name] = b
        time.sleep(0.05)
print("step 3: fixtures uploaded (find-n6: older, main; old-phone: empty)")


def tree(d: Path):
    """Every file under home except outputs: path -> (sha256, mtime_ns)."""
    out = {}
    for p in sorted(d.rglob("*")):
        if p.is_file() and "money" not in p.relative_to(d).parts and p.name != "server.log":
            out[str(p.relative_to(d))] = (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
    return out


before = tree(home)
out = tmpdir("clarity-money-out-")


def close(a, b):
    return isinstance(a, (int, float)) and not isinstance(a, bool) and abs(a - b) < EPS


def same(got, want, where="summary"):
    """want is the pinned shape: dict keys must all be present (extra keys allowed), lists exact length."""
    if isinstance(want, dict):
        need(isinstance(got, dict), f"{where}: expected an object, got {got!r}")
        for k, v in want.items():
            need(k in got, f"{where}: missing key {k!r} (have {sorted(got)})")
            same(got[k], v, f"{where}.{k}")
    elif isinstance(want, list):
        need(isinstance(got, list) and len(got) == len(want),
             f"{where}: expected a list of {len(want)}, got {json.dumps(got, ensure_ascii=False)[:600]}")
        for i, (g, w) in enumerate(zip(got, want)):
            same(g, w, f"{where}[{i}]")
    elif isinstance(want, float):
        need(close(got, want), f"{where}: expected {want}, got {got!r}")
    elif isinstance(want, str) and len(want) > 19 and want[10] == "T":
        try:
            g = datetime.fromisoformat(got)
        except (TypeError, ValueError):
            fail(f"{where}: expected an ISO 8601 datetime with offset, got {got!r}")
        need(g.utcoffset() is not None, f"{where}: {got!r} has no UTC offset; give local time with offset")
        need(g == datetime.fromisoformat(want), f"{where}: expected {want} (same instant), got {got!r}")
    else:
        need(got == want and type(got) is type(want), f"{where}: expected {want!r}, got {got!r}")


def summary(*args, env=None):
    p = out / f"summary-{time.monotonic_ns()}.json"
    r = clarity(home, "money", "summary", "--today", F.TODAY, "--out", str(p), *args, env=env)
    need(r.returncode == 0, f"`clarity money summary {' '.join(args)}` failed:\n{show(r)}")
    try:
        printed = json.loads(r.stdout)
    except json.JSONDecodeError:
        fail(f"`clarity money summary` must print exactly the JSON object on stdout (messages go to stderr):\n{r.stdout[:800]}")
    need(p.is_file(), f"`clarity money summary --out {p}` did not write the file")
    written = json.loads(p.read_text(encoding="utf-8"))
    need(written == printed, "the --out file and stdout must hold the same JSON")
    for c in printed.get("currencies", []) + printed.get("accounts", []):
        for k in ("spent", "income"):
            need(not isinstance(c.get(k), (int, float)) or c[k] >= 0,
                 f"{c.get('currency')} {c.get('name', '')} {k}={c.get(k)}: spent and income are positive sums "
                 "(expenses are stored negative; spent = minus their sum)")
    return printed


# ---- step 4: the summary of device find-n6's newest backup -------------------------------------
got = summary("--device", "find-n6")
same(got, F.EXPECT_MAIN)
m = ids["main"]
same(got["backup"], {"id": m["id"], "sha256": m["sha256"], "device": "find-n6", "db_schema": 48})
need(close(got["backup"].get("ts"), m["ts"]), f"summary.backup.ts must be the stored backup's ts {m['ts']}, got {got['backup'].get('ts')!r}")
for key, obj, ts in (("backup.at", got["backup"].get("at"), m["ts"]), ("generated_at", got.get("generated_at"), time.time())):
    try:
        v = datetime.fromisoformat(obj)
    except (TypeError, ValueError):
        fail(f"summary.{key} must be an ISO 8601 datetime with offset, got {obj!r}")
    need(v.utcoffset() is not None and abs(v.timestamp() - ts) < 120, f"summary.{key} is wrong or has no offset: {obj!r}")
print("step 4: summary of find-n6's newest backup (totals, categories, 7 days, accounts, budgets, freshness): ok")

# ---- step 5: no --device = newest backup of any device (old-phone: an empty month) -------------
got = summary()
same(got, F.EXPECT_EMPTY, "summary(empty month)")
need(got["backup"]["id"] == ids["empty"]["id"], "without --device the newest backup of any device must be used")
r = clarity(home, "money", "summary", "--today", F.TODAY)
need(r.returncode == 0, f"`clarity money summary` without --out failed:\n{show(r)}")
need((home / "data" / "money" / "summary.json").is_file(), "default --out must be $CLARITY_DATA/money/summary.json")
print("step 5: newest backup of any device, empty month, default --out: ok")

# ---- step 6: the month CSV --------------------------------------------------------------------
p = out / "oct.csv"
r = clarity(home, "money", "csv", "--device", "find-n6", "--month", "2026-10", "--today", F.TODAY, "--out", str(p))
need(r.returncode == 0 and p.is_file(), f"`clarity money csv --month 2026-10` failed:\n{show(r)}")
gotb = p.read_bytes()
if gotb != F.GOLDEN_OCT_CSV:
    gl, wl = gotb.decode("utf-8", "replace").split("\r\n"), F.GOLDEN_OCT_CSV.decode().split("\r\n")
    diff = next((i for i, (a, b) in enumerate(zip(gl, wl)) if a != b), min(len(gl), len(wl)))
    fail("the October CSV differs from the app's export format.\n"
         f"  records: got {len(gl)}, want {len(wl)} (records are joined by CRLF, no trailing line break, no BOM)\n"
         f"  first difference at record {diff}:\n    got:  {gl[diff] if diff < len(gl) else '<none>'!r}\n"
         f"    want: {wl[diff] if diff < len(wl) else '<none>'!r}")
r = clarity(home, "money", "csv", "--device", "find-n6", "--today", F.TODAY)
d = home / "data" / "money" / "clarity-2026-10.csv"
need(r.returncode == 0 and d.is_file(), f"default month (last month) / default --out $CLARITY_DATA/money/clarity-YYYY-MM.csv:\n{show(r)}")
need(d.read_bytes() == F.GOLDEN_OCT_CSV, "with no --month the CSV must be last month's (2026-10 when today is 2026-11-12)")
p = out / "empty.csv"
r = clarity(home, "money", "csv", "--device", "old-phone", "--month", "2026-10", "--today", F.TODAY, "--out", str(p))
need(r.returncode == 0 and p.is_file(), f"an empty month must still write the CSV (header only):\n{show(r)}")
need(p.read_bytes() == F.CSV_HEADER.encode(), f"an empty month's CSV is the header line alone, got {p.read_bytes()[:300]!r}")
print("step 6: October CSV byte-exact, default month and path, empty month: ok")

# ---- step 7: the local time zone decides months and days (process TZ, not hard-coded) ----------
got = summary("--device", "find-n6", env={"TZ": "UTC"})
cny = next((c for c in got.get("currencies", []) if c.get("currency") == "CNY"), None)
need(cny is not None and close(cny.get("spent"), F.EXPECT_UTC_CNY_SPENT),
     f"under TZ=UTC the 2026-11-01 00:30 (+08:00) row is October: CNY spent must be {F.EXPECT_UTC_CNY_SPENT}, got {cny and cny.get('spent')}")
p = out / "oct-utc.csv"
r = clarity(home, "money", "csv", "--device", "find-n6", "--month", "2026-10", "--today", F.TODAY, "--out", str(p), env={"TZ": "UTC"})
need(r.returncode == 0, f"csv under TZ=UTC failed:\n{show(r)}")
t = p.read_text(encoding="utf-8")
need(F.UTC_OCT_MUST_HAVE in t and F.UTC_OCT_MUST_NOT_HAVE not in t,
     "under TZ=UTC the October CSV must gain the Oct 31 16:30 UTC row (printed in UTC) and lose the Sep 30 16:10 UTC one")
print("step 7: month and day boundaries follow the process's local time zone: ok")

# ---- step 8: the seam: summarize() builds, write_summary() is the only writer ------------------
os.environ.update({"CLARITY_DB": str(home / "clarity.db"), "CLARITY_DATA": str(home / "data"), "TZ": "Asia/Shanghai"})
time.tzset()
sys.path.insert(0, str(SERVER))
from clarity_server import cli, money  # noqa: E402

for fn in ("summarize", "write_summary"):
    need(callable(getattr(money, fn, None)), f"clarity_server/money.py must define {fn}()")
calls = []
real_write = money.write_summary
money.write_summary = lambda summary, out_path: calls.append((summary, str(out_path)))
seam_out = out / "seam.json"
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = cli.main(["money", "summary", "--device", "find-n6", "--today", F.TODAY, "--out", str(seam_out)])
money.write_summary = real_write
need(rc == 0, f"cli.main(money summary) returned {rc}")
need(len(calls) == 1 and calls[0][1] == str(seam_out),
     f"cli must write the summary through exactly one call money.write_summary(summary, out_path), got {len(calls)} call(s)")
need(not seam_out.exists(), "something other than money.write_summary wrote the --out file")
need(json.loads(buf.getvalue()) == calls[0][0], "the printed JSON must be the dict handed to write_summary")
blob = home / "data" / "backups" / f"{ids['main']['sha256']}.sqlite"
direct = money.summarize(blob, backup=ids["main"], today=date.fromisoformat(F.TODAY))
need({k: v for k, v in direct.items() if k != "generated_at"} == {k: v for k, v in calls[0][0].items() if k != "generated_at"},
     "money.summarize(backup_path, backup=<stored backup row>, today=date) must return the same summary the CLI writes")
real_write(direct, out / "real-write.json")
need(json.loads((out / "real-write.json").read_text(encoding="utf-8")) == direct, "write_summary(summary, path) must write that JSON")
print("step 8: summarize()/write_summary() seam: ok")

# ---- step 9: nothing under the server's DB or stored backups changed ----------------------------
after = tree(home)
for k in sorted(set(before) | set(after)):
    if k == "clarity.db-shm":
        continue   # SQLite's shared-memory index; a mode=ro reader of a WAL database creates it
    if k == "clarity.db-wal" and k not in before:
        need((home / k).stat().st_size == 0, "clarity.db-wal has content: something wrote to the server database")
        continue
    need(before.get(k) == after.get(k), f"{k} was {'created' if k not in before else 'changed or removed'}: "
         "open the server DB with mode=ro and each backup read-only (a WAL-mode backup with immutable=1 or a temp copy)")
print("step 9: server DB and stored backups untouched: ok")

# ---- step 10: refusals: plain message, non-zero, no output file --------------------------------


def refuses(why, h, *args, must_mention=()):
    for sub in ("summary", "csv"):
        p = out / f"refused-{time.monotonic_ns()}"
        r = clarity(h, "money", sub, "--today", F.TODAY, "--out", str(p), *args)
        need(r.returncode != 0, f"`money {sub}` must fail on {why}:\n{show(r)}")
        need(r.stderr.strip() and "Traceback" not in r.stderr, f"`money {sub}` on {why}: give a plain message on stderr, not a traceback:\n{show(r)}")
        for w in must_mention:
            need(w in r.stderr, f"`money {sub}` on {why}: the message must name {w!r}:\n{r.stderr}")
        need(not p.exists(), f"`money {sub}` on {why} wrote {p}")


nodb = tmpdir("clarity-money-nodb-")
refuses("no server database", nodb)
need(not (nodb / "clarity.db").exists() and not (nodb / "data").exists(), "the command created the server DB or data dir: it must only read")
refuses("an unknown device", home, "--device", "no-such-phone")
for v, name in ((47, "v47"), (49, "v49")):
    h = tmpdir(f"clarity-money-{name}-")
    with Server(h) as s:
        tok = s.pair("find-n6")
        raw = fx[name].read_bytes()
        st, _ = http("POST", s.base + "/api/v1/backups", token=tok, raw=raw, headers={"X-Content-Sha256": sha(raw)})
        need(st == 200, f"upload {name} failed")
    refuses(f"a schema v{v} backup", h, must_mention=(str(v),))
fresh = tmpdir("clarity-money-fresh-")
with Server(fresh) as s:
    pass
refuses("a server with no backups yet", fresh)
print("step 10: no DB, no backup, unknown device, schema v47 and v49 refused plainly: ok")
print("money-summary OK")
