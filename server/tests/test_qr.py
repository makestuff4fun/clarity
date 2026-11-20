"""`clarity device pair --qr / --qr-file` (segno). Skipped until the venv has segno."""
import json

import pytest

pytest.importorskip("segno")

from clarity_server import cli, qr  # noqa: E402


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("CLARITY_DB", str(tmp_path / "clarity.db"))
    monkeypatch.setenv("CLARITY_DATA", str(tmp_path / "data"))


def test_json_stays_pure_with_qr(env, capsys, tmp_path):
    f = tmp_path / "p.svg"
    assert cli.main(["device", "pair", "phone", "--json", "--qr", "--qr-file", str(f)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert set(out) == {"code", "link", "expires"}
    assert f.read_text().lstrip().startswith("<?xml") and (f.stat().st_mode & 0o077) == 0


def test_qr_draws_the_link(env, capsys):
    assert cli.main(["device", "pair", "phone", "--qr"]) == 0
    out = capsys.readouterr().out
    link = next(ln.strip() for ln in out.splitlines() if ln.strip().startswith("clarity://"))
    assert qr.terminal(link, color=False).splitlines()[0] in out  # same size/quiet zone
    assert "▀" in out or "▄" in out


def test_bad_qr_file_mints_nothing(env, capsys, tmp_path):
    assert cli.main(["device", "pair", "phone", "--qr-file", str(tmp_path / "p.jpg")]) == 2
    capsys.readouterr()
    import sqlite3
    con = sqlite3.connect(tmp_path / "clarity.db")
    assert con.execute("SELECT count(*) FROM pair_codes").fetchone()[0] == 0
