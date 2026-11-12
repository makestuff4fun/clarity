"""Tests for clarity money summary and clarity money csv."""
import hashlib
import json
import sqlite3
import time
from datetime import date, datetime
from zoneinfo import ZoneInfo

import pytest

from clarity_server import backups, cli, db, money

SHANGHAI = ZoneInfo("Asia/Shanghai")

DDL = """
CREATE TABLE wallets (
    wallet_pk TEXT PRIMARY KEY, name TEXT NOT NULL, colour TEXT, icon_name TEXT,
    date_created INTEGER NOT NULL, date_time_modified INTEGER, "order" INTEGER NOT NULL,
    currency TEXT, currency_format TEXT, decimals INTEGER NOT NULL DEFAULT 2,
    home_page_widget_display TEXT, archived INTEGER NOT NULL DEFAULT 0, emoji_icon_name TEXT
);
CREATE TABLE categories (
    category_pk TEXT PRIMARY KEY, name TEXT NOT NULL, colour TEXT, icon_name TEXT,
    emoji_icon_name TEXT, date_created INTEGER NOT NULL, date_time_modified INTEGER,
    "order" INTEGER NOT NULL, income INTEGER NOT NULL DEFAULT 0, method_added INTEGER,
    main_category_pk TEXT, archived INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE objectives (
    objective_pk TEXT PRIMARY KEY, type INTEGER NOT NULL DEFAULT 0, name TEXT NOT NULL,
    amount REAL NOT NULL, "order" INTEGER NOT NULL, colour TEXT, date_created INTEGER NOT NULL,
    end_date INTEGER, date_time_modified INTEGER, icon_name TEXT, emoji_icon_name TEXT,
    income INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 1,
    archived INTEGER NOT NULL DEFAULT 0, wallet_fk TEXT NOT NULL DEFAULT '0'
);
CREATE TABLE transactions (
    transaction_pk TEXT PRIMARY KEY, paired_transaction_fk TEXT, name TEXT NOT NULL,
    amount REAL NOT NULL, note TEXT NOT NULL, category_fk TEXT NOT NULL,
    sub_category_fk TEXT, wallet_fk TEXT NOT NULL DEFAULT '0', date_created INTEGER NOT NULL,
    date_time_modified INTEGER, original_date_due INTEGER, income INTEGER NOT NULL DEFAULT 0,
    period_length INTEGER, reoccurrence INTEGER, end_date INTEGER,
    upcoming_transaction_notification INTEGER DEFAULT 1, type INTEGER,
    paid INTEGER NOT NULL DEFAULT 0, created_another_future_transaction INTEGER DEFAULT 0,
    skip_paid INTEGER NOT NULL DEFAULT 0, method_added INTEGER, transaction_owner_email TEXT,
    transaction_original_owner_email TEXT, shared_key TEXT, shared_old_key TEXT,
    shared_status INTEGER, shared_date_updated INTEGER, shared_reference_budget_pk TEXT,
    objective_fk TEXT, objective_loan_fk TEXT, budget_fks_exclude TEXT
);
CREATE TABLE budgets (
    budget_pk TEXT PRIMARY KEY, name TEXT NOT NULL, amount REAL NOT NULL, colour TEXT,
    start_date INTEGER NOT NULL, end_date INTEGER NOT NULL, wallet_fks TEXT,
    category_fks TEXT, category_fks_exclude TEXT, income INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0, added_transactions_only INTEGER NOT NULL DEFAULT 0,
    period_length INTEGER NOT NULL, reoccurrence INTEGER, date_created INTEGER NOT NULL,
    date_time_modified INTEGER, pinned INTEGER NOT NULL DEFAULT 0, "order" INTEGER NOT NULL,
    wallet_fk TEXT NOT NULL DEFAULT '0', budget_transaction_filters TEXT,
    member_transaction_filters TEXT, shared_key TEXT, shared_owner_member INTEGER,
    shared_date_updated INTEGER, shared_members TEXT, shared_all_members_ever TEXT,
    is_absolute_spending_limit INTEGER NOT NULL DEFAULT 0
);
"""


def _ts(s: str) -> int:
    return int(datetime.strptime(s, "%Y-%m-%d %H:%M").replace(tzinfo=SHANGHAI).timestamp())


def _make_backup(path, *, version=48):
    c = sqlite3.connect(path)
    c.executescript(DDL)
    c.execute("INSERT INTO wallets (wallet_pk, name, date_created, \"order\", currency, archived) VALUES ('0', 'Cash', 0, 0, 'cny', 0)")
    c.execute("INSERT INTO categories (category_pk, name, colour, icon_name, date_created, \"order\", income) VALUES ('1', 'Food', '0xff42a5f5', 'cutlery.png', 0, 0, 0)")
    c.execute("INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, income, paid, period_length, reoccurrence) VALUES ('t1', 'Noodles', -25.0, ' spicy ', '1', '0', ?, 0, 1, 1, 3)", (_ts("2026-11-10 12:00"),))
    c.execute("INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, income, paid, period_length, reoccurrence) VALUES ('t2', 'Tea', -15.0, '', '1', '0', ?, 0, 1, 1, 3)", (_ts("2026-10-15 14:00"),))
    c.execute(f"PRAGMA user_version={version}")
    c.commit()
    c.close()
    return path.read_bytes()


def test_summary_and_csv(tmp_path, monkeypatch, capsys):
    dbp, data = tmp_path / "clarity.db", tmp_path / "data"
    monkeypatch.setenv("CLARITY_DB", str(dbp))
    monkeypatch.setenv("CLARITY_DATA", str(data))
    monkeypatch.setenv("TZ", "Asia/Shanghai")
    time.tzset()

    db.init(str(dbp))
    raw = _make_backup(tmp_path / "v48.sqlite")
    con = db.connect(str(dbp))
    bk = backups.store(con, str(data), raw, hashlib.sha256(raw).hexdigest(), "find-n6", 1762900000.0)
    con.close()

    assert cli.main(["money", "summary", "--today", "2026-11-12"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["currencies"][0] == {
        "currency": "CNY",
        "spent": 25.0,
        "income": 0.0,
        "count": 1,
        "by_category": [{"name": "Food", "spent": 25.0, "count": 1, "other": False}],
        "last_7_days": [
            {"date": "2026-11-06", "spent": 0.0},
            {"date": "2026-11-07", "spent": 0.0},
            {"date": "2026-11-08", "spent": 0.0},
            {"date": "2026-11-09", "spent": 0.0},
            {"date": "2026-11-10", "spent": 25.0},
            {"date": "2026-11-11", "spent": 0.0},
            {"date": "2026-11-12", "spent": 0.0},
        ],
    }
    assert json.loads((data / "money" / "summary.json").read_text(encoding="utf-8")) == out

    blob = data / "backups" / f"{bk['sha256']}.sqlite"
    direct = money.summarize(blob, backup=bk, today=date(2026, 11, 12))
    assert direct["currencies"] == out["currencies"]

    assert cli.main(["money", "csv", "--today", "2026-11-12", "--month", "2026-11"]) == 0
    nov_csv = (data / "money" / "clarity-2026-11.csv").read_bytes().decode("utf-8")
    lines = nov_csv.split("\r\n")
    assert len(lines) == 2
    assert '" spicy "' in lines[1]


def test_refusals_do_not_create_db_or_out(tmp_path, monkeypatch, capsys):
    dbp, data, out = tmp_path / "missing.db", tmp_path / "data", tmp_path / "out.json"
    monkeypatch.setenv("CLARITY_DB", str(dbp))
    monkeypatch.setenv("CLARITY_DATA", str(data))

    assert cli.main(["money", "summary", "--today", "2026-11-12", "--out", str(out)]) == 1
    assert not dbp.exists() and not data.exists() and not out.exists()

    db.init(str(dbp))
    raw47 = _make_backup(tmp_path / "v47.sqlite", version=47)
    con = db.connect(str(dbp))
    backups.store(con, str(data), raw47, hashlib.sha256(raw47).hexdigest(), "find-n6", 1762900000.0)
    con.close()

    capsys.readouterr()
    assert cli.main(["money", "summary", "--today", "2026-11-12", "--out", str(out)]) == 1
    assert "47" in capsys.readouterr().err
    assert not out.exists()
