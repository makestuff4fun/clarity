"""clarity money: read-only monthly summary JSON and Cashew 6.7.5 CSV export from the newest backup.

The summary is built by summarize() and written only by write_summary(), keeping a clean seam for
future delivery into den's records store.
"""
import calendar
import json
import re
import sqlite3
import time
from datetime import date, datetime, timedelta
from pathlib import Path

from . import backups

SCHEMA_VERSION = 48
TOP_CATEGORIES = 5

CSV_COLUMNS = (
    "account",
    "amount",
    "amount unpaid",
    "currency",
    "title",
    "note",
    "date",
    "income",
    "type",
    "category name",
    "subcategory name",
    "color",
    "icon",
    "emoji",
    "budget",
    "objective",
    "extra",
)

_TX_TYPES = {
    0: "upcoming",
    1: "subscription",
    2: "repetitive",
    3: "credit",
    4: "debt",
}

_REOCCURRENCE_UNITS = {
    0: "custom",
    1: "day",
    2: "week",
    3: "month",
    4: "year",
}

_MONTH_RE = re.compile(r"^(\d{4})-(0[1-9]|1[0-2])$")


class MoneyError(Exception):
    pass


def _sync_tz() -> None:
    if hasattr(time, "tzset"):
        time.tzset()


def _local_dt(ts: float | int) -> datetime:
    return datetime.fromtimestamp(ts).astimezone()


def _iso_local(ts: float | int) -> str:
    return _local_dt(ts).isoformat(timespec="seconds")


def parse_today(raw: str | None) -> date:
    _sync_tz()
    if not raw:
        return datetime.now().astimezone().date()
    try:
        return date.fromisoformat(raw)
    except ValueError:
        raise MoneyError(f"invalid --today date {raw!r} (expected YYYY-MM-DD)")


def resolve_month(raw: str | None, today: date) -> tuple[int, int, str]:
    if not raw:
        if today.month == 1:
            y, m = today.year - 1, 12
        else:
            y, m = today.year, today.month - 1
        return y, m, f"{y:04d}-{m:02d}"
    m_obj = _MONTH_RE.fullmatch(raw.strip())
    if not m_obj:
        raise MoneyError(f"invalid --month {raw!r} (expected YYYY-MM)")
    y, m = int(m_obj.group(1)), int(m_obj.group(2))
    return y, m, f"{y:04d}-{m:02d}"


def newest_backup(db_path: str | Path, data_dir: str | Path, device: str | None = None) -> tuple[Path, dict]:
    db_file = Path(db_path)
    if not db_file.is_file():
        raise MoneyError(f"server database not found at {db_file}")
    try:
        con = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True, timeout=30)
    except sqlite3.Error as e:
        raise MoneyError(f"cannot open server database {db_file}: {e}")
    con.row_factory = sqlite3.Row
    try:
        if device is not None:
            row = con.execute(
                "SELECT * FROM backups WHERE device=? ORDER BY ts DESC, rowid DESC LIMIT 1",
                (device,),
            ).fetchone()
            if row is None:
                raise MoneyError(f"no backup found for unknown device {device!r}")
        else:
            row = con.execute(
                "SELECT * FROM backups ORDER BY ts DESC, rowid DESC LIMIT 1"
            ).fetchone()
            if row is None:
                raise MoneyError("no backups stored yet")
        bk = backups._row(row)
    except sqlite3.Error as e:
        raise MoneyError(f"cannot read backups table from {db_file}: {e}")
    finally:
        con.close()

    blob = backups.backup_dir(str(data_dir)) / f"{bk['sha256']}.sqlite"
    if not blob.is_file():
        raise MoneyError(f"backup file missing at {blob}")
    return blob, bk


def _open_backup(backup_path: str | Path) -> sqlite3.Connection:
    p = Path(backup_path)
    if not p.is_file():
        raise MoneyError(f"backup file not found at {p}")
    try:
        con = sqlite3.connect(f"file:{p}?mode=ro&immutable=1", uri=True)
    except sqlite3.Error as e:
        raise MoneyError(f"cannot open backup {p}: {e}")
    con.row_factory = sqlite3.Row
    try:
        v = con.execute("PRAGMA user_version").fetchone()[0]
    except Exception as e:
        con.close()
        raise MoneyError(f"cannot read schema version from {p}: {e}")
    if v != SCHEMA_VERSION:
        con.close()
        raise MoneyError(f"unsupported backup schema version {v} (expected {SCHEMA_VERSION})")
    return con


def _parse_json_list(raw: str | None) -> list[str] | None:
    if not raw:
        return None
    try:
        val = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if isinstance(val, list) and val:
        return [str(x) for x in val]
    return None


def _add_months(d: date, months: int) -> date:
    total = d.year * 12 + (d.month - 1) + months
    y, m = divmod(total, 12)
    m += 1
    last_day = calendar.monthrange(y, m)[1]
    return date(y, m, min(d.day, last_day))


def _budget_period(b: sqlite3.Row, today: date) -> tuple[date, date] | None:
    rec = b["reoccurrence"]
    plen = int(b["period_length"] or 0)
    s0 = _local_dt(b["start_date"]).date()
    if rec == 0:  # custom
        e0 = _local_dt(b["end_date"]).date()
        return (s0, e0) if s0 <= today <= e0 else None
    if plen <= 0:
        return None
    if rec == 3:  # monthly
        diff_months = (today.year - s0.year) * 12 + (today.month - s0.month)
        k0 = diff_months // plen
        for k in (k0 - 1, k0, k0 + 1):
            p_start = _add_months(s0, k * plen)
            p_end = _add_months(s0, (k + 1) * plen) - timedelta(days=1)
            if p_start <= today <= p_end:
                return p_start, p_end
        return None
    if rec == 4:  # yearly
        step = 12 * plen
        diff_months = (today.year - s0.year) * 12 + (today.month - s0.month)
        k0 = diff_months // step
        for k in (k0 - 1, k0, k0 + 1):
            p_start = _add_months(s0, k * step)
            p_end = _add_months(s0, (k + 1) * step) - timedelta(days=1)
            if p_start <= today <= p_end:
                return p_start, p_end
        return None
    if rec in (1, 2):  # daily, weekly
        step_days = plen if rec == 1 else plen * 7
        diff_days = (today - s0).days
        k = diff_days // step_days
        p_start = s0 + timedelta(days=k * step_days)
        p_end = p_start + timedelta(days=step_days - 1)
        return (p_start, p_end) if p_start <= today <= p_end else None
    return None


def summarize(backup_path: str | Path, *, backup: dict, today: date) -> dict:
    _sync_tz()
    con = _open_backup(backup_path)
    try:
        wallets = {
            r["wallet_pk"]: r
            for r in con.execute('SELECT * FROM wallets ORDER BY "order" ASC, wallet_pk ASC')
        }
        categories = {
            r["category_pk"]: r
            for r in con.execute('SELECT * FROM categories ORDER BY "order" ASC, category_pk ASC')
        }
        budgets_rows = con.execute(
            'SELECT * FROM budgets WHERE archived=0 AND income=0 AND added_transactions_only=0 '
            'ORDER BY "order" ASC, budget_pk ASC'
        ).fetchall()
        tx_rows = con.execute("SELECT * FROM transactions").fetchall()
    finally:
        con.close()

    month_start = today.replace(day=1)
    seven_days = [today - timedelta(days=i) for i in range(6, -1, -1)]
    seven_days_set = set(seven_days)

    # Track currencies: every currency of a non-archived wallet plus any currency with counted rows.
    currencies_set: set[str] = set()
    for w in wallets.values():
        if not w["archived"]:
            cur = (w["currency"] or "").upper()
            if cur:
                currencies_set.add(cur)

    newest_paid_ts: int | None = None
    counted_txs: list[dict] = []

    for r in tx_rows:
        ts = r["date_created"]
        tx_date = _local_dt(ts).date()
        if r["paid"] == 1 and tx_date <= today:
            if newest_paid_ts is None or ts > newest_paid_ts:
                newest_paid_ts = ts

        if (
            r["paid"] == 1
            and r["category_fk"] != "0"
            and r["objective_loan_fk"] is None
            and r["type"] not in (3, 4)
        ):
            w = wallets.get(r["wallet_fk"])
            cat = categories.get(r["category_fk"])
            if w is None or cat is None:
                continue
            cur = (w["currency"] or "").upper()
            amt = float(r["amount"])
            is_income = r["income"] == 1
            counted_txs.append({
                "row": r,
                "date": tx_date,
                "wallet_pk": r["wallet_fk"],
                "wallet_name": w["name"],
                "currency": cur,
                "category_fk": r["category_fk"],
                "sub_category_fk": r["sub_category_fk"],
                "category_name": cat["name"],
                "income": is_income,
                "spent": 0.0 if is_income else -amt,
                "income_amt": amt if is_income else 0.0,
                "budget_exclude": _parse_json_list(r["budget_fks_exclude"]) or [],
            })

    # Month-so-far counted rows
    month_txs = [t for t in counted_txs if month_start <= t["date"] <= today]
    for t in month_txs:
        if t["currency"]:
            currencies_set.add(t["currency"])

    # Build currency summaries
    cur_data: dict[str, dict] = {
        cur: {
            "currency": cur,
            "spent": 0.0,
            "income": 0.0,
            "count": 0,
            "cats": {},
            "days": {d: 0.0 for d in seven_days},
        }
        for cur in currencies_set
    }

    for t in counted_txs:
        cur = t["currency"]
        if not t["income"] and t["date"] in seven_days_set and cur in cur_data:
            cur_data[cur]["days"][t["date"]] += t["spent"]

    # Accounts with at least one counted row this month
    acct_data: dict[str, dict] = {}

    for t in month_txs:
        cur = t["currency"]
        entry = cur_data[cur]
        wpk = t["wallet_pk"]
        if wpk not in acct_data:
            acct_data[wpk] = {
                "name": t["wallet_name"],
                "currency": cur,
                "spent": 0.0,
                "income": 0.0,
                "count": 0,
            }
        acct = acct_data[wpk]
        if t["income"]:
            entry["income"] += t["income_amt"]
            acct["income"] += t["income_amt"]
        else:
            entry["spent"] += t["spent"]
            entry["count"] += 1
            acct["spent"] += t["spent"]
            acct["count"] += 1
            cname = t["category_name"]
            if cname not in entry["cats"]:
                entry["cats"][cname] = {"name": cname, "spent": 0.0, "count": 0}
            entry["cats"][cname]["spent"] += t["spent"]
            entry["cats"][cname]["count"] += 1

    currencies_out = []
    for cur, d in sorted(cur_data.items(), key=lambda kv: (-round(kv[1]["spent"], 10), kv[0])):
        cats_sorted = sorted(
            d["cats"].values(),
            key=lambda c: (-round(c["spent"], 10), c["name"]),
        )
        by_cat = [
            {
                "name": c["name"],
                "spent": round(c["spent"], 10),
                "count": c["count"],
                "other": False,
            }
            for c in cats_sorted[:TOP_CATEGORIES]
        ]
        if len(cats_sorted) > TOP_CATEGORIES:
            rest = cats_sorted[TOP_CATEGORIES:]
            by_cat.append({
                "name": "other",
                "spent": round(sum(c["spent"] for c in rest), 10),
                "count": sum(c["count"] for c in rest),
                "other": True,
            })
        currencies_out.append({
            "currency": cur,
            "spent": round(d["spent"], 10),
            "income": round(d["income"], 10),
            "count": d["count"],
            "by_category": by_cat,
            "last_7_days": [
                {"date": day.isoformat(), "spent": round(d["days"][day], 10)}
                for day in seven_days
            ],
        })

    accounts_out = [
        {
            "name": a["name"],
            "currency": a["currency"],
            "spent": round(a["spent"], 10),
            "income": round(a["income"], 10),
            "count": a["count"],
        }
        for a in sorted(
            acct_data.values(),
            key=lambda a: (a["currency"], -round(a["spent"], 10), a["name"]),
        )
    ]

    budgets_out = []
    for b in budgets_rows:
        period = _budget_period(b, today)
        if period is None:
            continue
        p_start, p_end = period
        bw = wallets.get(b["wallet_fk"])
        b_cur = (bw["currency"] or "").upper() if bw else ""
        wfks = _parse_json_list(b["wallet_fks"])
        cfks = _parse_json_list(b["category_fks"])
        cfks_ex = _parse_json_list(b["category_fks_exclude"])
        b_pk = b["budget_pk"]

        b_spent = 0.0
        for t in counted_txs:
            if t["income"]:
                continue
            if not (p_start <= t["date"] <= today):
                continue
            if t["currency"] != b_cur:
                continue
            if wfks is not None and t["wallet_pk"] not in wfks:
                continue
            if cfks is not None and t["category_fk"] not in cfks and t["sub_category_fk"] not in cfks:
                continue
            if cfks_ex is not None and (t["category_fk"] in cfks_ex or t["sub_category_fk"] in cfks_ex):
                continue
            if b_pk in t["budget_exclude"]:
                continue
            b_spent += t["spent"]

        b_amt = float(b["amount"])
        budgets_out.append({
            "name": b["name"],
            "currency": b_cur,
            "amount": round(b_amt, 10),
            "spent": round(b_spent, 10),
            "left": round(b_amt - b_spent, 10),
            "period_start": p_start.isoformat(),
            "period_end": p_end.isoformat(),
        })

    return {
        "schema": 1,
        "generated_at": _iso_local(time.time()),
        "today": today.isoformat(),
        "month": f"{today.year:04d}-{today.month:02d}",
        "backup": {
            "id": backup["id"],
            "sha256": backup["sha256"],
            "device": backup["device"],
            "ts": backup["ts"],
            "at": _iso_local(backup["ts"]),
            "db_schema": SCHEMA_VERSION,
        },
        "newest_transaction": _iso_local(newest_paid_ts) if newest_paid_ts is not None else None,
        "currencies": currencies_out,
        "accounts": accounts_out,
        "budgets": budgets_out,
    }


def write_summary(summary: dict, out_path: str | Path) -> None:
    p = Path(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _csv_field(val: str) -> str:
    if not val:
        return ""
    if (
        "," in val
        or '"' in val
        or "\r" in val
        or "\n" in val
        or val.startswith(" ")
        or val.endswith(" ")
    ):
        return '"' + val.replace('"', '""') + '"'
    return val


def _csv_encode(rows: list[list[str]]) -> str:
    return "\r\n".join(",".join(_csv_field(f) for f in row) for row in rows)


def build_csv(backup_path: str | Path, *, year: int, month: int) -> str:
    _sync_tz()
    con = _open_backup(backup_path)
    try:
        wallets = {r["wallet_pk"]: r for r in con.execute("SELECT * FROM wallets")}
        categories = {r["category_pk"]: r for r in con.execute("SELECT * FROM categories")}
        budgets = {r["budget_pk"]: r for r in con.execute("SELECT * FROM budgets")}
        objectives = {r["objective_pk"]: r for r in con.execute("SELECT * FROM objectives")}
        tx_rows = con.execute(
            "SELECT rowid AS _rowid, * FROM transactions ORDER BY date_created DESC, _rowid ASC"
        ).fetchall()
    finally:
        con.close()

    records: list[list[str]] = [list(CSV_COLUMNS)]
    for tx in tx_rows:
        dt = _local_dt(tx["date_created"])
        if dt.year != year or dt.month != month:
            continue
        w = wallets.get(tx["wallet_fk"])
        cat = categories.get(tx["category_fk"])
        if w is None or cat is None:
            continue
        sub = categories.get(tx["sub_category_fk"]) if tx["sub_category_fk"] else None
        b = budgets.get(tx["shared_reference_budget_pk"]) if tx["shared_reference_budget_pk"] else None
        obj = objectives.get(tx["objective_fk"]) if tx["objective_fk"] else None

        amt_str = repr(float(tx["amount"]))
        paid = tx["paid"] == 1
        amount_col = amt_str if paid else ""
        unpaid_col = "" if paid else amt_str

        t_code = tx["type"]
        type_str = "default" if t_code is None else _TX_TYPES.get(t_code, "default")

        color_str = (cat["colour"] or "").upper()
        icon_raw = cat["icon_name"] or ""
        icon_str = icon_raw[:-4] if icon_raw.endswith(".png") else icon_raw
        emoji_str = cat["emoji_icon_name"] or ""

        plen = tx["period_length"]
        rec = tx["reoccurrence"]
        if plen is not None and rec is not None and rec in _REOCCURRENCE_UNITS:
            extra_str = f"repeat every {plen} {_REOCCURRENCE_UNITS[rec]}"
        else:
            extra_str = ""

        records.append([
            w["name"] or "",
            amount_col,
            unpaid_col,
            (w["currency"] or "").upper(),
            tx["name"] or "",
            tx["note"] or "",
            dt.strftime("%Y-%m-%d %H:%M:%S.000"),
            "true" if tx["income"] == 1 else "false",
            type_str,
            cat["name"] or "",
            (sub["name"] or "") if sub else "",
            color_str,
            icon_str,
            emoji_str,
            (b["name"] or "") if b else "",
            (obj["name"] or "") if obj else "",
            extra_str,
        ])

    return _csv_encode(records)


def write_csv(content: str, out_path: str | Path) -> None:
    p = Path(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(content.encode("utf-8"))
