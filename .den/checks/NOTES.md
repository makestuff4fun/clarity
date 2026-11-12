# money-summary: what the check pins (read this before building)

Files: `check_money_summary.py` (the check), `money_fixtures.py` (fixture builder plus the expected
answers, worked by hand). Run from the repo root after `.den/setup.sh`:

    server/.venv/bin/python .den/checks/check_money_summary.py

The check needs no Flutter and no network. It starts the real server only to upload fixtures, the
same way `check_server_backup.py` does. A full run takes about 10 s plus `server/bin/check`.

## Commands (in `server/clarity_server/cli.py`, next to `device` and `backup`)

    clarity money summary [--device NAME] [--today YYYY-MM-DD] [--out PATH]
    clarity money csv     [--device NAME] [--today YYYY-MM-DD] [--month YYYY-MM] [--out PATH]

- Both commands read the server database from `CLARITY_DB` and the backups from `CLARITY_DATA`, the
  same as the other commands.
- **Newest backup.** With `--device`, it is the newest `backups` row for that device. Without it, it
  is the newest row of any device. Rows are ordered by `ts DESC, rowid DESC`. The file is
  `$CLARITY_DATA/backups/<sha256>.sqlite`.
- `--today` defaults to the local date. The check always passes it.
- `summary` prints the JSON object on stdout, and only that: messages go to stderr. It writes the
  same JSON to `--out`, by default `$CLARITY_DATA/money/summary.json`.
- `csv` writes the month's CSV to `--out`, by default `$CLARITY_DATA/money/clarity-YYYY-MM.csv`. The
  month defaults to the month before `--today`.
- **Refusals.** Both commands refuse each of the following with a plain stderr line (no traceback), a
  non-zero exit, and no output file:
  - `CLARITY_DB` missing. The command must not create the DB or the data dir.
  - No backups yet.
  - An unknown `--device`.
  - `PRAGMA user_version` other than **48**. The message names the version it found.

## The seam (records-store delivery is NOT in this task)

- `clarity_server/money.py` must define `summarize(backup_path, *, backup, today)`. It returns the
  summary dict and writes nothing. `backup` is the stored row as `backups._row` gives it (`id`,
  `sha256`, `bytes`, `ts`, `device`). `today` is a `datetime.date`.
- `money.py` must also define `write_summary(summary, out_path)`. This is the only code that writes
  the summary.
- The CLI calls these two functions as `money.summarize(...)` and `money.write_summary(...)`, with
  the module name in front, because the check replaces `money.write_summary` to prove it is the only
  writer.
- den-fleet has not said yet how a job on red writes a den record. When it does, the put goes beside
  or inside `write_summary`, and nothing else changes.

## Read-only

- Open the server DB with `file:...?mode=ro`. SQLite then creates an empty `clarity.db-wal` and
  `-shm` for a WAL database, and the check allows that.
- Open each backup with `mode=ro&immutable=1`, or read a temp copy of it. A WAL-header backup opened
  with plain `mode=ro` leaves `-wal`/`-shm` files in `data/backups/`, and the check fails on that.
  The `old-phone` fixture is a WAL-header file on purpose.
- Every other file under the DB and the data dir must keep its exact bytes and mtime.

## Amount conventions (from tables.dart, exportCSV.dart and the v48 schema; checked against a real v48 file's structure)

- `amount` is REAL. Expenses are stored negative (`income=0`) and income positive (`income=1`).
  Dates are INTEGER unix seconds (drift).
- **Counted rows.** A row counts toward totals when it has `paid=1`, `category_fk != '0'`,
  `objective_loan_fk IS NULL` and `type NOT IN (3,4)` (credit/debt). These are the app's own
  `isNotLoan` and balance-correction filters.
  - Category `"0"` is "Balance Correction". Transfers between accounts are two `"0"` rows, `+x` and
    `-x`, so they never count.
  - Unpaid rows (`paid=0`: upcoming, or repetitive not yet paid) never count.
  - `skip_paid` is ignored. The real data has `skip_paid=1` on ordinary paid rows.
- **Expense or income.** The `income` flag decides. `spent` is minus the sum of the counted expense
  amounts, a positive number. `income` is the sum of the counted income amounts. A refund entered as
  income in an expense category is income: it does not reduce spending.
- **Category.** A row's category is `category_fk`, the main category. Subcategory rows roll up into
  it.

## Time zone (pinned: the process's local zone, i.e. honour `TZ`)

- The phone writes local wall-clock `DateTime`s as unix seconds. Brian's phone and red are both
  Asia/Shanghai.
- Months, days, "today", the last 7 days and every printed datetime use the zone of the process
  running the command. On red that is the system zone. Do not hard-code +08:00.
- The check runs with `TZ=Asia/Shanghai` and once with `TZ=UTC`, which moves the boundary rows
  (`2026-11-01 00:30` and `2026-10-01 00:10`, both +08:00) into the previous month.

## Summary JSON (`schema: 1`); money values are compared to 0.005 and may carry extra keys

    {"schema": 1, "generated_at": ISO+offset, "today": "YYYY-MM-DD", "month": "YYYY-MM",
     "backup": {"id", "sha256", "device", "ts": <stored ts>, "at": ISO+offset, "db_schema": 48},
     "newest_transaction": ISO+offset | null,
     "currencies": [{"currency": "CNY", "spent", "income", "count",
                     "by_category": [{"name", "spent", "count", "other": false}, ..., {"name": "other", ..., "other": true}],
                     "last_7_days": [{"date": "YYYY-MM-DD", "spent"} x 7, oldest first, ending today]}],
     "accounts": [{"name", "currency", "spent", "income", "count"}],
     "budgets": [{"name", "currency", "amount", "spent", "left", "period_start", "period_end"}]}

- **"So far".** Counted rows dated from the 1st of `today`'s month through the end of `today`. A paid
  row dated later this month is not counted.
- **`newest_transaction`** is the newest `date_created` of any `paid=1` row (any category) dated no
  later than the end of today. The card uses it to show how fresh the data is.
- **Currencies.** One block per currency (upper case). The blocks cover every currency of a
  non-archived wallet, even at 0, plus any currency that has counted rows. They are sorted by
  `spent` descending, then by code. **Amounts in different currencies are never added or
  converted.**
- **`count`** is the number of counted *expense* rows.
- **`by_category`** is per currency, sorted by `spent` descending, then by name. It shows the top
  **5**. If any categories remain, one more entry follows: `{"name": "other", "other": true}`, with
  the summed spent and count of the rest. A month with no spending gives `[]`.
- **`accounts`** lists the wallets with at least one counted row this month. They are sorted by
  currency, then `spent` descending, then name.
- **`budgets`** covers non-archived budgets with `income=0` and `added_transactions_only=0`, in the
  `"order"` column's order.
  - **Monthly** (`reoccurrence=3`, `period_length n`): the periods are anchored on the day of
    `start_date`. The current period is the one that contains today; the fixture tests the 1st and
    the 5th.
  - **Custom** (`reoccurrence=0`): the period runs from `start_date` to `end_date`.
  - A budget whose current period does not contain today is left out. Daily, weekly and yearly
    budgets are not pinned.
  - `spent` uses the same counted expense rows, "so far" within the period. Rows count only if they
    are in the budget's currency (`wallet_fk`'s), in `wallet_fks` when that is set, and in
    `category_fks` when that is set. Rows in `category_fks_exclude` are dropped, as are rows whose
    `budget_fks_exclude` lists this budget. `left = amount - spent`, which may be negative.

## CSV (byte-exact golden in `money_fixtures.GOLDEN_OCT_CSV`)

The header is the 17 columns of Brian's real exports from Cashew 6.7.5, the files he files with
invoices:

    account,amount,amount unpaid,currency,title,note,date,income,type,category name,subcategory name,color,icon,emoji,budget,objective,extra

**This is not Clarity's own `exportCSV.dart`.** That file has 15 columns, with no `amount unpaid`
and no `extra`. It also prints `TransactionSpecialType.x`, raw lower-case colours and `.png` icon
names, and exports only paid rows. The task asks for the file that replaces his manual export, so
the check pins the 6.7.5 format. Every rule below was read off the structure of a real 6.7.5 export
(`cashew-2026-11-01-…csv`, 309 rows; no values were copied). Both apps format dates, booleans and
numbers the same way (Dart `toString`).

**Rows**
- Every transaction whose local date falls in the month, paid or not, transfers and loans included.
- Inner-joined to its main category and its wallet.
- Ordered by `date_created DESC`. Ties go to `rowid ASC`; the two legs of a transfer share a
  timestamp.

**Column values**
- `amount`: Dart's `double.toString`, so `-68.0`, `-129.9`, `5000.0`. Python's `repr(float(x))` is
  the same below 1e16. For an unpaid row, `amount` is empty and `amount unpaid` holds the amount.
- `currency`: the wallet's currency in upper case.
- `date`: local `YYYY-MM-DD HH:MM:SS.000`.
- `income`: `true` or `false`.
- `type`: `default` when NULL, else `upcoming`, `subscription`, `repetitive`, `credit` or `debt`.
- `category name`, `color`, `icon` and `emoji` come from the main category. `subcategory name` comes
  from `sub_category_fk`.
- `color`: upper case, so `0XFF42A5F5`. It is empty when NULL.
- `icon`: `icon_name` without its `.png`.
- `budget` comes from `shared_reference_budget_pk`. `objective` comes from `objective_fk`.
- `extra`: `repeat every {period_length} {day|week|month|year}` when both `period_length` and
  `reoccurrence` are set, else empty. Only `1 month` and empty were observed. The plural for n > 1
  is unverified.

**Encoding**
- UTF-8 with no BOM. Records are joined by CRLF with no trailing line break (Dart `csv` 8.0.0
  defaults).
- A field is quoted only if it contains `,`, `"`, CR or LF, or starts or ends with a space. Inside
  quotes, `"` becomes `""`. Python's `csv` module does not quote leading or trailing spaces and adds
  a trailing line break, so write the encoder by hand.
- An empty month gives the header line alone, with exit 0.

## Fixtures (invented rows, real v48 DDL embedded)

- **`main`** (`find-n6`, newest): about 28 rows covering expense, income, a refund-as-income,
  transfers, an unpaid upcoming and an unpaid repetitive row, a credit loan, an objective-loan row,
  a future paid row, a subcategory, two currencies, an archived EUR wallet, three live budgets plus
  one archived, and rows on both month boundaries.
- **`older`** (`find-n6`, older): one row. Using it gives the wrong totals.
- **`empty`** (`old-phone`, uploaded last, WAL header): nothing this month.
- **`v47` / `v49`**: `main` with another `user_version`.
