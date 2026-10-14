"""clarity backup run / verify against a local directory standing in for tunnel-bear."""
import hashlib
import sqlite3
import time

from clarity_server import backup, backups, cli, db


def test_run_then_verify(tmp_path, monkeypatch, capsys):
    dbp, data, remote = tmp_path / "clarity.db", tmp_path / "data", tmp_path / "remote"
    for k, v in (("CLARITY_DB", dbp), ("CLARITY_DATA", data), ("CLARITY_BACKUP_DIR", tmp_path / "local"),
                 ("CLARITY_BACKUP_REMOTE", f"{remote}/")):
        monkeypatch.setenv(k, str(v))
    db.init(str(dbp))
    blob = tmp_path / "b.sqlite"
    c = sqlite3.connect(blob)
    c.execute("CREATE TABLE t (v)")
    c.commit()
    c.close()
    raw = blob.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    con = db.connect(str(dbp))
    backups.store(con, str(data), raw, digest, "phone", time.time())
    con.close()

    assert cli.main(["backup", "run"]) == 0
    assert (remote / "backups" / f"{digest}.sqlite").read_bytes() == raw
    assert len(list((remote / "hourly").glob("clarity-*.db"))) == 1
    assert cli.main(["backup", "verify"]) == 0
    assert "remote_backups=1 snapshot=clarity-" in capsys.readouterr().out

    (remote / "backups" / f"{digest}.sqlite").write_bytes(b"tampered")
    assert cli.main(["backup", "verify"]) == 1
    assert "does not hash" in capsys.readouterr().err


def test_prune_keeps_newest(tmp_path):
    for h in range(50):
        (tmp_path / f"clarity-20261014T{h % 24:02d}{h // 24:02d}00Z.db").touch()
    backup._prune(tmp_path, backup.HOURLY_RE, backup.KEEP_HOURLY)
    assert len(list(tmp_path.iterdir())) == 48
