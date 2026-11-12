"""Fixtures for check_money_summary.py: small Clarity v48 databases built from the app's own schema,
with INVENTED rows (never Brian's), and the answers the check expects. PROTECTED (.den/**).

The DDL below is the exact `sqlite_master.sql` of a real Clarity/Cashew v48 database (the schema only:
budget/lib/database/tables.dart compiled by drift, user_version 48). Dates are INTEGER unix seconds, as
drift writes them; booleans are 0/1. Every fixture time is written as a wall-clock time in
Asia/Shanghai (Brian's phone and red), converted to epoch seconds here with an explicit zone, so the
fixture bytes do not depend on the TZ of the process that builds them.

Run directly to build the three fixtures into a directory and print a short description:
    server/.venv/bin/python .den/checks/money_fixtures.py /tmp/some-dir
"""
import json
import sqlite3
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo("Asia/Shanghai")
TODAY = "2026-11-12"           # passed as --today to every run
SCHEMA_VERSION = 48            # PRAGMA user_version of a Clarity database this feature understands

V48_DDL = """
CREATE TABLE "wallets" ("wallet_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "colour" TEXT NULL, "icon_name" TEXT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "order" INTEGER NOT NULL, "currency" TEXT NULL, "currency_format" TEXT NULL, "decimals" INTEGER NOT NULL DEFAULT 2, "home_page_widget_display" TEXT NULL DEFAULT NULL, "archived" INTEGER NOT NULL DEFAULT (0) CHECK ("archived" IN (0, 1)), "emoji_icon_name" TEXT NULL, PRIMARY KEY ("wallet_pk"));
CREATE TABLE "categories" ("category_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "colour" TEXT NULL, "icon_name" TEXT NULL, "emoji_icon_name" TEXT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "order" INTEGER NOT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "method_added" INTEGER NULL, "main_category_pk" TEXT NULL DEFAULT NULL REFERENCES categories (category_pk), "archived" INTEGER NOT NULL DEFAULT (0) CHECK ("archived" IN (0, 1)), PRIMARY KEY ("category_pk"));
CREATE TABLE "objectives" ("objective_pk" TEXT NOT NULL, "type" INTEGER NOT NULL DEFAULT 0, "name" TEXT NOT NULL, "amount" REAL NOT NULL, "order" INTEGER NOT NULL, "colour" TEXT NULL, "date_created" INTEGER NOT NULL, "end_date" INTEGER NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "icon_name" TEXT NULL, "emoji_icon_name" TEXT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "pinned" INTEGER NOT NULL DEFAULT 1 CHECK ("pinned" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), PRIMARY KEY ("objective_pk"));
CREATE TABLE "transactions" ("transaction_pk" TEXT NOT NULL, "paired_transaction_fk" TEXT NULL DEFAULT NULL REFERENCES transactions (transaction_pk), "name" TEXT NOT NULL, "amount" REAL NOT NULL, "note" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "sub_category_fk" TEXT NULL DEFAULT NULL REFERENCES categories (category_pk), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "original_date_due" INTEGER NULL DEFAULT 1762956245, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "period_length" INTEGER NULL, "reoccurrence" INTEGER NULL, "end_date" INTEGER NULL, "upcoming_transaction_notification" INTEGER NULL DEFAULT 1 CHECK ("upcoming_transaction_notification" IN (0, 1)), "type" INTEGER NULL, "paid" INTEGER NOT NULL DEFAULT 0 CHECK ("paid" IN (0, 1)), "created_another_future_transaction" INTEGER NULL DEFAULT 0 CHECK ("created_another_future_transaction" IN (0, 1)), "skip_paid" INTEGER NOT NULL DEFAULT 0 CHECK ("skip_paid" IN (0, 1)), "method_added" INTEGER NULL, "transaction_owner_email" TEXT NULL, "transaction_original_owner_email" TEXT NULL, "shared_key" TEXT NULL, "shared_old_key" TEXT NULL, "shared_status" INTEGER NULL, "shared_date_updated" INTEGER NULL, "shared_reference_budget_pk" TEXT NULL, "objective_fk" TEXT NULL REFERENCES objectives (objective_pk), "objective_loan_fk" TEXT NULL REFERENCES objectives (objective_pk), "budget_fks_exclude" TEXT NULL, PRIMARY KEY ("transaction_pk"));
CREATE TABLE "budgets" ("budget_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "amount" REAL NOT NULL, "colour" TEXT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "wallet_fks" TEXT NULL, "category_fks" TEXT NULL, "category_fks_exclude" TEXT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "added_transactions_only" INTEGER NOT NULL DEFAULT 0 CHECK ("added_transactions_only" IN (0, 1)), "period_length" INTEGER NOT NULL, "reoccurrence" INTEGER NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "pinned" INTEGER NOT NULL DEFAULT 0 CHECK ("pinned" IN (0, 1)), "order" INTEGER NOT NULL, "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "budget_transaction_filters" TEXT NULL DEFAULT NULL, "member_transaction_filters" TEXT NULL DEFAULT NULL, "shared_key" TEXT NULL, "shared_owner_member" INTEGER NULL, "shared_date_updated" INTEGER NULL, "shared_members" TEXT NULL, "shared_all_members_ever" TEXT NULL, "is_absolute_spending_limit" INTEGER NOT NULL DEFAULT 0 CHECK ("is_absolute_spending_limit" IN (0, 1)), PRIMARY KEY ("budget_pk"));
CREATE TABLE "category_budget_limits" ("category_limit_pk" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "budget_fk" TEXT NOT NULL REFERENCES budgets (budget_pk), "amount" REAL NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), PRIMARY KEY ("category_limit_pk"));
CREATE TABLE "associated_titles" ("associated_title_pk" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "title" TEXT NOT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "order" INTEGER NOT NULL, "is_exact_match" INTEGER NOT NULL DEFAULT 0 CHECK ("is_exact_match" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT (0) CHECK ("archived" IN (0, 1)), PRIMARY KEY ("associated_title_pk"));
CREATE TABLE "app_settings" ("settings_pk" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "settings_j_s_o_n" TEXT NOT NULL, "date_updated" INTEGER NOT NULL);
CREATE TABLE "scanner_templates" ("scanner_template_pk" TEXT NOT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL DEFAULT 1762956245, "template_name" TEXT NOT NULL, "contains" TEXT NOT NULL, "title_transaction_before" TEXT NOT NULL, "title_transaction_after" TEXT NOT NULL, "amount_transaction_before" TEXT NOT NULL, "amount_transaction_after" TEXT NOT NULL, "default_category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "ignore" INTEGER NOT NULL DEFAULT 0 CHECK ("ignore" IN (0, 1)), "default_title" TEXT NULL DEFAULT (NULL), PRIMARY KEY ("scanner_template_pk"));
CREATE TABLE "delete_logs" ("delete_log_pk" TEXT NOT NULL, "entry_pk" TEXT NOT NULL, "type" INTEGER NOT NULL, "date_time_modified" INTEGER NOT NULL DEFAULT 1762956245, PRIMARY KEY ("delete_log_pk"));
CREATE TABLE "tags" ("date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "order" INTEGER NOT NULL, "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "name" TEXT NOT NULL, "colour" TEXT NULL, "icon_name" TEXT NULL, "emoji_icon_name" TEXT NULL, "tag_pk" TEXT NOT NULL, PRIMARY KEY ("tag_pk"));
CREATE TABLE "transaction_to_tag_links" ("transaction_pk" TEXT NULL REFERENCES transactions (transaction_pk), "tag_pk" TEXT NULL REFERENCES tags (tag_pk), PRIMARY KEY ("transaction_pk", "tag_pk"));
"""

# TransactionSpecialType: upcoming 0, subscription 1, repetitive 2, credit 3, debt 4 (tables.dart)
UPCOMING, SUBSCRIPTION, REPETITIVE, CREDIT, DEBT = range(5)
# BudgetReoccurence: custom 0, daily 1, weekly 2, monthly 3, yearly 4
CUSTOM, DAILY, WEEKLY, MONTHLY, YEARLY = range(5)


def at(s: str) -> int:
    """'2026-11-12 09:15' wall clock in Asia/Shanghai -> unix seconds."""
    return int(datetime.strptime(s, "%Y-%m-%d %H:%M").replace(tzinfo=SHANGHAI).timestamp())


T0 = at("2026-01-01 00:00")    # created / modified stamps nobody reads

WALLETS = [  # pk, name, currency (lower case, as the app stores it), archived, order
    ("0", "Cash", "cny", 0, 0),
    ("w-card", "Card", "cny", 0, 1),
    ("w-usd", "USD Card", "usd", 0, 2),
    ("w-old", "Old", "eur", 1, 3),          # archived, no rows: must not appear anywhere
]
CATEGORIES = [  # pk, name, colour, icon_name, emoji, income, main_category_pk
    ("0", "Balance Correction", "0xff607d8b", "charts.png", None, 0, None),   # transfers + corrections
    ("1", "Food", "0xff42a5f5", "cutlery.png", None, 0, None),
    ("1a", "Coffee", "0xff8d6e63", "coffee.png", None, 0, "1"),              # subcategory of Food
    ("2", "Transport", None, "tram.png", None, 0, None),
    ("3", "Shopping", "0xffab47bc", "shopping.png", None, 0, None),
    ("4", "Bills", "0xffef5350", "bills.png", None, 0, None),
    ("5", "Health", "0xff66bb6a", "health.png", None, 0, None),
    ("6", "Gifts", "0xffffa726", "gift.png", None, 0, None),
    ("7", "Salary", None, "coins.png", "\U0001F4B0", 1, None),
    ("8", "Travel", "0xff26a69a", "plane.png", None, 0, None),
]
OBJECTIVES = [  # pk, type (0 goal, 1 loan), name
    ("o-trip", 0, "Trip fund"),
    ("o-loan", 1, "Loan to Sam"),
]


def tx(pk, title, amount, cat, wallet, when, *, sub=None, income=False, paid=True, skip_paid=False,
       type_=None, period=(1, MONTHLY), note="", paired=None, budget=None, objective=None, loan=None):
    """One transactions row. period=(1, MONTHLY) is what the app writes on ordinary rows."""
    return dict(transaction_pk=pk, paired_transaction_fk=paired, name=title, amount=amount, note=note,
                category_fk=cat, sub_category_fk=sub, wallet_fk=wallet, date_created=at(when),
                date_time_modified=T0, original_date_due=at(when), income=int(income),
                period_length=period[0] if period else None, reoccurrence=period[1] if period else None,
                type=type_, paid=int(paid), skip_paid=int(skip_paid),
                shared_reference_budget_pk=budget, objective_fk=objective, objective_loan_fk=loan)


# The main fixture: device find-n6's newest backup. Comments say what each row tests.
MAIN_TX = [
    # ---- November 2026, month so far (today = 2026-11-12) ----
    tx("n01", "Lunch", -45.5, "1", "0", "2026-11-12 09:15"),
    tx("n02", "Coffee", -28.0, "1", "w-card", "2026-11-11 08:30", sub="1a"),  # a subcategory row: rolls up to Food
    tx("n03", "Metro", -6.0, "2", "0", "2026-11-10 18:00"),
    tx("n04", "Jacket", -199.99, "3", "w-card", "2026-11-08 20:00"),
    tx("n05", "Electricity", -300.0, "4", "w-card", "2026-11-05 10:00", skip_paid=True),  # skip_paid=1 is normal on paid rows: counts
    tx("n06", "Pharmacy", -80.0, "5", "0", "2026-11-03 12:00"),
    tx("n07", "Flowers", -50.0, "6", "0", "2026-11-02 15:00"),
    tx("n08", "Taxi to airport", -20.0, "8", "0", "2026-11-01 00:30"),         # local Nov 1 = UTC Oct 31 16:30
    tx("n09", "Salary", 5000.0, "7", "w-card", "2026-11-01 09:00", income=True),
    tx("n10", "Refund", 30.0, "3", "w-card", "2026-11-09 11:00", income=True),  # income flag wins: income, not negative spend
    tx("n11a", "Transfer", 1000.0, "0", "0", "2026-11-06 12:00", income=True, period=None, paired="n11b"),
    tx("n11b", "Transfer", -1000.0, "0", "w-card", "2026-11-06 12:00", period=None, paired="n11a"),
    tx("n12", "Water bill", -120.0, "4", "w-card", "2026-11-07 09:00", paid=False, type_=UPCOMING),  # unpaid: not spent
    tx("n13", "Lent to friend", -500.0, "1", "0", "2026-11-04 10:00", type_=CREDIT),  # loan: not spending
    tx("n14", "Dinner booked", -15.0, "1", "0", "2026-11-20 12:00"),          # after today: not "so far"
    tx("n15", "Bagel", -12.5, "1", "w-usd", "2026-11-10 13:00"),
    tx("n16", "Hotel", -100.0, "8", "w-usd", "2026-11-12 01:00"),             # local Nov 12 = UTC Nov 11
    tx("n17", "Loan payment", -70.0, "1", "0", "2026-11-09 14:00", loan="o-loan"),  # objective loan: not spending
    # ---- October 2026 (the default CSV month) ----
    tx("o01", "Dinner", -60.0, "1", "0", "2026-10-31 23:30"),
    tx("o02", 'Shoes, "red"', -129.9, "3", "w-card", "2026-10-25 19:45", note="size 42\nreturn by 30th"),
    tx("o05", "Rent top-up", -250.0, "4", "w-card", "2026-10-22 09:00", paid=False, type_=REPETITIVE),
    tx("o03a", "Transfer", 500.0, "0", "0", "2026-10-20 12:00", income=True, period=None, paired="o03b"),
    tx("o03b", "Transfer", -500.0, "0", "w-card", "2026-10-20 12:00", period=None, paired="o03a"),
    tx("o04", "Phone plan", -68.0, "4", "w-card", "2026-10-15 08:00", type_=SUBSCRIPTION, budget="b-monthly"),
    tx("o08", "Taxi", -45.25, "8", "w-usd", "2026-10-10 14:00"),
    tx("o06", "Salary", 5000.0, "7", "w-card", "2026-10-01 09:00", income=True),
    tx("o07", "Latte", -33.3, "1", "0", "2026-10-01 00:10", sub="1a", note=" gift", objective="o-trip"),  # local Oct 1 = UTC Sep 30
    # ---- September ----
    tx("s01", "Snack", -10.0, "1", "0", "2026-09-30 23:59"),
]
BUDGETS = [  # pk, name, amount, start, end, wallet_fk, category_fks, reoccurrence, period_length, archived, order
    ("b-monthly", "Monthly", 2000.0, "2026-01-01 00:00", "2026-01-31 23:59", "0", None, MONTHLY, 1, 0, 0),
    ("b-groc", "Groceries", 400.0, "2026-06-05 00:00", "2026-07-04 23:59", "0", ["1"], MONTHLY, 1, 0, 1),
    ("b-trip", "Trip", 300.0, "2026-11-10 00:00", "2026-11-15 23:59", "w-usd", ["8"], CUSTOM, 0, 0, 2),
    ("b-old", "Old plan", 999.0, "2026-01-01 00:00", "2026-01-31 23:59", "0", None, MONTHLY, 1, 1, 3),  # archived
]

OLDER_TX = [tx("x01", "Older backup row", -999.0, "1", "0", "2026-11-02 12:00")]   # find-n6's OLDER backup
EMPTY_TX = [tx("e01", "Snack", -10.0, "1", "0", "2026-09-15 12:00")]               # old-phone: nothing this month


def build(path: Path, rows, *, budgets=(), user_version=SCHEMA_VERSION, wal=False) -> Path:
    path = Path(path)
    path.unlink(missing_ok=True)
    c = sqlite3.connect(path)
    c.executescript(V48_DDL)
    c.executemany('INSERT INTO wallets (wallet_pk, name, colour, icon_name, date_created, date_time_modified, '
                  '"order", currency, currency_format, decimals, archived) VALUES (?,?,NULL,NULL,?,?,?,?,NULL,2,?)',
                  [(pk, n, T0, T0, o, cur, a) for pk, n, cur, a, o in WALLETS])
    c.executemany('INSERT INTO categories (category_pk, name, colour, icon_name, emoji_icon_name, date_created, '
                  'date_time_modified, "order", income, main_category_pk) VALUES (?,?,?,?,?,?,?,?,?,?)',
                  [(pk, n, col, ic, em, T0, T0, i, inc, main) for i, (pk, n, col, ic, em, inc, main) in enumerate(CATEGORIES)])
    c.executemany('INSERT INTO objectives (objective_pk, type, name, amount, "order", date_created) VALUES (?,?,?,?,?,?)',
                  [(pk, t, n, 1000.0, i, T0) for i, (pk, t, n) in enumerate(OBJECTIVES)])
    for r in rows:
        cols = ", ".join(f'"{k}"' for k in r)
        c.execute(f"INSERT INTO transactions ({cols}) VALUES ({', '.join('?' * len(r))})", list(r.values()))
    for pk, n, amt, s, e, w, cats, rec, plen, arch, o in budgets:
        c.execute('INSERT INTO budgets (budget_pk, name, amount, start_date, end_date, wallet_fks, category_fks, income, '
                  'archived, added_transactions_only, period_length, reoccurrence, date_created, "order", wallet_fk) '
                  'VALUES (?,?,?,?,?,NULL,?,0,?,0,?,?,?,?,?)',
                  (pk, n, amt, at(s), at(e), json.dumps(cats) if cats else None, arch, plen, rec, T0, o, w))
    c.execute(f"PRAGMA user_version={int(user_version)}")
    c.commit()
    if wal:   # a WAL-mode header: opening it with mode=ro would create -wal/-shm beside it
        c.execute("PRAGMA journal_mode=WAL")
    c.close()
    for side in ("-wal", "-shm", "-journal"):
        Path(str(path) + side).unlink(missing_ok=True)
    return path


def build_all(d: Path) -> dict:
    d = Path(d)
    d.mkdir(parents=True, exist_ok=True)
    return {
        "main": build(d / "main.sqlite", MAIN_TX, budgets=BUDGETS),
        "older": build(d / "older.sqlite", OLDER_TX),
        "empty": build(d / "empty.sqlite", EMPTY_TX, wal=True),
        "v47": build(d / "v47.sqlite", MAIN_TX, budgets=BUDGETS, user_version=47),
        "v49": build(d / "v49.sqlite", MAIN_TX, budgets=BUDGETS, user_version=49),
    }


# ---------------------------------------------------------------- expected answers (TZ=Asia/Shanghai)
# Worked by hand from the rows above, not computed by any implementation. Money is compared to 0.005.
def _days(**spent):
    days = ["2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12"]
    return [{"date": d, "spent": spent.get("d" + d[-2:], 0.0)} for d in days]


EXPECT_MAIN = {
    "schema": 1,
    "today": "2026-11-12",
    "month": "2026-11",
    "newest_transaction": "2026-11-12T09:15:00+08:00",   # n01; n14 (Nov 20) is after today
    "currencies": [
        {"currency": "CNY", "spent": 729.49, "income": 5030.0, "count": 8,
         "by_category": [
             {"name": "Bills", "spent": 300.0, "count": 1, "other": False},
             {"name": "Shopping", "spent": 199.99, "count": 1, "other": False},
             {"name": "Health", "spent": 80.0, "count": 1, "other": False},
             {"name": "Food", "spent": 73.5, "count": 2, "other": False},
             {"name": "Gifts", "spent": 50.0, "count": 1, "other": False},
             {"name": "other", "spent": 26.0, "count": 2, "other": True},     # Travel 20 + Transport 6
         ],
         "last_7_days": _days(d08=199.99, d10=6.0, d11=28.0, d12=45.5)},
        {"currency": "USD", "spent": 112.5, "income": 0.0, "count": 2,
         "by_category": [
             {"name": "Travel", "spent": 100.0, "count": 1, "other": False},
             {"name": "Food", "spent": 12.5, "count": 1, "other": False},
         ],
         "last_7_days": _days(d10=12.5, d12=100.0)},
    ],
    "accounts": [
        {"name": "Card", "currency": "CNY", "spent": 527.99, "income": 5030.0, "count": 3},
        {"name": "Cash", "currency": "CNY", "spent": 201.5, "income": 0.0, "count": 5},
        {"name": "USD Card", "currency": "USD", "spent": 112.5, "income": 0.0, "count": 2},
    ],
    "budgets": [
        {"name": "Monthly", "currency": "CNY", "amount": 2000.0, "spent": 729.49, "left": 1270.51,
         "period_start": "2026-11-01", "period_end": "2026-11-30"},
        {"name": "Groceries", "currency": "CNY", "amount": 400.0, "spent": 73.5, "left": 326.5,
         "period_start": "2026-11-05", "period_end": "2026-12-04"},
        {"name": "Trip", "currency": "USD", "amount": 300.0, "spent": 100.0, "left": 200.0,
         "period_start": "2026-11-10", "period_end": "2026-11-15"},
    ],
}

EXPECT_EMPTY = {
    "schema": 1,
    "today": "2026-11-12",
    "month": "2026-11",
    "newest_transaction": "2026-09-15T12:00:00+08:00",
    "currencies": [{"currency": "CNY", "spent": 0.0, "income": 0.0, "count": 0, "by_category": [],
                    "last_7_days": _days()},
                   {"currency": "USD", "spent": 0.0, "income": 0.0, "count": 0, "by_category": [],
                    "last_7_days": _days()}],   # every currency of a non-archived wallet, even at 0
    "accounts": [],
    "budgets": [],
}

# Under TZ=UTC n08 (local Nov 1 00:30) falls in October: CNY spent drops by 20.
EXPECT_UTC_CNY_SPENT = 709.49

CSV_HEADER = ("account,amount,amount unpaid,currency,title,note,date,income,type,category name,"
              "subcategory name,color,icon,emoji,budget,objective,extra")

# October 2026, TZ=Asia/Shanghai. CRLF between records, no trailing line break, no BOM, UTF-8.
GOLDEN_OCT_CSV = "\r\n".join([
    CSV_HEADER,
    "Cash,-60.0,,CNY,Dinner,,2026-10-31 23:30:00.000,false,default,Food,,0XFF42A5F5,cutlery,,,,repeat every 1 month",
    'Card,-129.9,,CNY,"Shoes, ""red""","size 42\nreturn by 30th",2026-10-25 19:45:00.000,false,default,Shopping,,0XFFAB47BC,shopping,,,,repeat every 1 month',
    "Card,,-250.0,CNY,Rent top-up,,2026-10-22 09:00:00.000,false,repetitive,Bills,,0XFFEF5350,bills,,,,repeat every 1 month",
    "Cash,500.0,,CNY,Transfer,,2026-10-20 12:00:00.000,true,default,Balance Correction,,0XFF607D8B,charts,,,,",
    "Card,-500.0,,CNY,Transfer,,2026-10-20 12:00:00.000,false,default,Balance Correction,,0XFF607D8B,charts,,,,",
    "Card,-68.0,,CNY,Phone plan,,2026-10-15 08:00:00.000,false,subscription,Bills,,0XFFEF5350,bills,,Monthly,,repeat every 1 month",
    "USD Card,-45.25,,USD,Taxi,,2026-10-10 14:00:00.000,false,default,Travel,,0XFF26A69A,plane,,,,repeat every 1 month",
    "Card,5000.0,,CNY,Salary,,2026-10-01 09:00:00.000,true,default,Salary,,,coins,\U0001F4B0,,,repeat every 1 month",
    'Cash,-33.3,,CNY,Latte," gift",2026-10-01 00:10:00.000,false,default,Food,Coffee,0XFF42A5F5,cutlery,,,Trip fund,repeat every 1 month',
]).encode("utf-8")

# Under TZ=UTC the October file gains n08 (printed in UTC) and loses o07 (Sep 30 16:10 UTC).
UTC_OCT_MUST_HAVE = "Cash,-20.0,,CNY,Taxi to airport,,2026-10-31 16:30:00.000,"
UTC_OCT_MUST_NOT_HAVE = "Latte"


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "money-fixtures")
    for k, p in build_all(out).items():
        c = sqlite3.connect(f"file:{p}?mode=ro&immutable=1", uri=True)   # mode=ro alone leaves -wal/-shm beside a WAL file
        n = c.execute("SELECT count(*) FROM transactions").fetchone()[0]
        v = c.execute("PRAGMA user_version").fetchone()[0]
        c.close()
        print(f"{k:6} {p}  user_version={v} transactions={n}")
