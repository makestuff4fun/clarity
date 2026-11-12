"""bin/clarity: clarity-server's command line. Honours CLARITY_DB and CLARITY_DATA.

    clarity device pair NAME [--json]   a one-time pairing code (10 minutes) and its clarity:// link
    clarity device list [--json]
    clarity device revoke NAME          effective on the device's next request
    clarity backup run                  snapshot the DB, rsync it and every stored backup off-box
    clarity backup verify               prove the off-box copy is fresh and complete (read-only)
"""
import argparse
import json
import sys
import time

from pathlib import Path

from . import backup, db, devices, money
from .app import default_data, default_db
from .errors import ApiError


def _fmt(t) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(t)) if t else "-"


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    ap = argparse.ArgumentParser(prog="clarity")
    sub = ap.add_subparsers(dest="cmd", required=True)
    dev = sub.add_parser("device", help="pair, list and revoke devices").add_subparsers(dest="sub", required=True)
    p = dev.add_parser("pair", help="print a one-time pairing code for device NAME")
    p.add_argument("name")
    p.add_argument("--scopes", default=devices.DEFAULT_SCOPES)
    p.add_argument("--json", action="store_true")
    p = dev.add_parser("list", help="list paired devices")
    p.add_argument("--json", action="store_true")
    p = dev.add_parser("revoke", help="revoke device NAME (from its next request)")
    p.add_argument("name")
    bk = sub.add_parser("backup", help="off-box copy to tunnel-bear").add_subparsers(dest="sub", required=True)
    bk.add_parser("run", help="snapshot and rsync to CLARITY_BACKUP_REMOTE")
    bk.add_parser("verify", help="check the remote copy (read-only)")
    mn = sub.add_parser("money", help="read-only monthly summary and CSV export from the newest backup").add_subparsers(dest="sub", required=True)
    p = mn.add_parser("summary", help="build the monthly money summary JSON")
    p.add_argument("--device", default=None, help="use the newest backup from this device")
    p.add_argument("--today", default=None, help="reference local date YYYY-MM-DD")
    p.add_argument("--out", default=None, help="output path (default $CLARITY_DATA/money/summary.json)")
    p = mn.add_parser("csv", help="export one month of transactions as CSV")
    p.add_argument("--device", default=None, help="use the newest backup from this device")
    p.add_argument("--today", default=None, help="reference local date YYYY-MM-DD")
    p.add_argument("--month", default=None, help="month to export YYYY-MM (default: month before --today)")
    p.add_argument("--out", default=None, help="output path (default $CLARITY_DATA/money/clarity-YYYY-MM.csv)")
    a = ap.parse_args(argv)

    path = default_db()
    if a.cmd == "backup":
        try:
            print(backup.run(a.sub, path, default_data()))
        except backup.BackupError as e:
            print(f"clarity backup {a.sub}: {e}", file=sys.stderr)
            return 1
        return 0
    if a.cmd == "money":
        data_dir = default_data()
        try:
            today = money.parse_today(a.today)
            blob, bk_row = money.newest_backup(path, data_dir, device=a.device)
            if a.sub == "summary":
                out_path = a.out or str(Path(data_dir) / "money" / "summary.json")
                summary = money.summarize(blob, backup=bk_row, today=today)
                money.write_summary(summary, out_path)
                print(json.dumps(summary, ensure_ascii=False))
            elif a.sub == "csv":
                y, m, ym = money.resolve_month(a.month, today)
                out_path = a.out or str(Path(data_dir) / "money" / f"clarity-{ym}.csv")
                csv_text = money.build_csv(blob, year=y, month=m)
                money.write_csv(csv_text, out_path)
        except money.MoneyError as e:
            print(f"clarity money {a.sub}: {e}", file=sys.stderr)
            return 1
        return 0
    db.init(path)
    con = db.connect(path)
    try:
        if a.sub == "pair":
            now = time.time()
            code = devices.new_pair_code(con, a.name, a.scopes, now)
            out = {"code": code, "link": devices.pair_link(code), "expires": now + devices.CODE_TTL}
            if a.json:
                print(json.dumps(out))
            else:
                print(f"pairing code for {a.name.strip()} (valid 10 minutes, once):\n  {code}\n"
                      f"link:\n  {out['link']}")
        elif a.sub == "list":
            rows = devices.list_devices(con)
            if a.json:
                print(json.dumps(rows))
            else:
                for d in rows:
                    print(f"{d['name']:<20} {' '.join(d['scopes']):<16} created {_fmt(d['created'])}  "
                          f"last seen {_fmt(d['last_seen'])} {d['last_ip'] or ''}"
                          f"{'  REVOKED' if d['revoked'] else ''}")
                if not rows:
                    print("no devices")
        elif a.sub == "revoke":
            if not devices.revoke(con, a.name):
                print(f"clarity: no live device named {a.name}", file=sys.stderr)
                return 1
            print(f"revoked {a.name}")
    except ApiError as e:
        print(f"clarity: {e.message}", file=sys.stderr)
        return 1
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
