"""bin/clarity: clarity-server's command line. Honours CLARITY_DB and CLARITY_DATA.

    clarity device pair NAME [--json]   a one-time pairing code (10 minutes) and its clarity:// link
    clarity device list [--json]
    clarity device revoke NAME          effective on the device's next request
"""
import argparse
import json
import sys
import time

from . import db, devices
from .app import default_db
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
    a = ap.parse_args(argv)

    path = default_db()
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
