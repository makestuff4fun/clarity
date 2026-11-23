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

# startup (`check_startup.sh`, 2026-11-20): Clarity must open, or say why it cannot

Clarity 5.5.0 froze on the splash: `hooks: user_defines: sqlite3: source: system` applied to every
OS, so the APK had no `libsqlite3.so`, `constructDb` threw in `main()`, and the empty zone handler in
`captureLogs` swallowed it. Run from the repo root: `bash .den/checks/check_startup.sh` (one release
build, a few minutes, plus `flutter test` on the startup guard).

- **Source checks** (`startup_pubspec.py`, grep): the `source` the hook resolves for `android` (the
  `android` key, else `default`, else the plain string) is not `system`/`process`/`executable`;
  `logging.dart`'s zone handler is not `{}`; `main.dart` runs `runStartup(...)` with a `database`
  step and `onError: handleStartupZoneError`; `bin/release` contains `NO_SQLITE_IN_APK`; version
  `5.5.1+418`.
- **APK**: `startup_release_apk.sh` runs `bin/release --dry-run` with a throwaway key in a temp
  HOME (never the real key, never `/srv/www`). `unzip -l` must list `lib/arm64-v8a/libsqlite3.so`,
  and `libsqlite3.so` for every ABI that has `libflutter.so`.
- **Dart** (`dart/startup_guard_test.dart`, 6 tests, needs only `struct/startupGuard.dart`): a
  throwing essential step shows "Clarity could not start" with the first line, Copy details and Try
  again; a throwing optional step falls back and the app opens; Try again reruns; an uncaught error
  before the first frame shows the screen, after it does not.

---

# den-hook (2026-11-20): what `check_den_hook.sh` pins

Contract: den-app `docs/MONEY.md`, "The hook, as pinned (2026-11-20)". Nothing in it was renamed.
Run: `bash .den/checks/check_den_hook.sh` (about 6-10 minutes; most of it is `bin/release --dry-run`).

## Pins

- **Source:** `den_hook_manifest.py`: `.den.DenHookProvider` exported at `com.clarity.finance.den`,
  no `permission`/`readPermission`/`writePermission`/`grantUriPermissions`; no exported component
  beyond the six Clarity had before (MainActivity, four widget receivers, the notification
  listener); `<queries>` names `com.hanquest.den`. `DenHookCaller.kt` pins the package and
  `DEN_CERT_SHA256 = 1931299e6edfeec066087b128e0af467e702f4e48836fde8df6adbe7f35a7a07`; the
  provider reads `signingCertificateHistory`; `call()` checks `Binder.getCallingUid()` before any
  work. The shell allowance is in `src/debug` only; `src/release` and `src/profile` answer `false`.
  `schemaVersionGlobal = 48`; `tables.dart` never mentions the hook; `denHook.dart` writes through
  `createOrUpdateTransaction`/`deleteTransaction`, matches with `getMainAndSubcategoryFromParams`
  and has no hand-written SQL. `version: 5.6.0+419`.
- **Dart** (`dart/den_hook_test.dart`, >= 12 tests, in-memory FinanceDatabase): hello
  `{ok, version, version_code, api: 1}`; add twice with one id = one row and the same answer;
  sign rule (expense stored negative, income positive, answer positive); names match like the add
  link (exact, case-insensitive, substring; pk first); unknown category/subcategory/account, no
  category, a non-positive amount or no id = `bad_args` with nothing saved and no category made;
  remove of a row not from the hook = `not_found`, remove writes a delete log, a second remove is
  `not_found` and a later add with that id is refused; recent newest first with the caller's id
  (null for Clarity's own rows), limit capped at 100; month in the local zone (rows at 00:30 on the
  1st and 23:00 on the 30th count, 00:01 on the next 1st does not), by_category sorted by spent;
  categories mains in `order` each followed by its subcategories (`parent_pk`); accounts with the
  default; nothing the app prints during a call escapes; the id file survives a new DenHook.
- **JVM** (`DenHookCallerTest`, >= 6, `gradle --offline :app:testReleaseUnitTest`): the pinned
  constants; wrong cert, wrong package, no package, no certs = denied; the shell only with the
  debug allowance; a pinned cert anywhere in a rotation history = allowed. Robolectric is not
  used: its android-all jars are not in the offline gradle cache, so the PackageManager lookup
  (`DenHookProvider.certsOf`) is not under test; the pure rule is.
- **APK:** `clarity-5.6.0.apk`; `libsqlite3.so` for every ABI with `libflutter.so` (check_startup's
  rule, which check_startup.sh itself now fails on only because it pins 5.5.1); the built manifest
  has the authority; the dex carries the pinned digest and NOT `den-hook-debug-shell-allowance`.

## Choices

- **Background path.** `DenHookProvider.call` (binder thread) checks the caller, then
  `DenHookEngine.call` posts to the main looper and waits at most 10 s (`busy` after). If
  MainActivity has attached its engine (`configureFlutterEngine` -> `attachUi`), the call goes to
  the app's own isolate over the MethodChannel `com.clarity.finance/den_hook`: the same
  FinanceDatabase instance does the write, so drift's streams refresh the open lists with no
  restart and there is one writer. Otherwise it starts a headless `FlutterEngine` on the Dart
  entrypoint `denHookMain` (main.dart: preferences, database, settings, backends, time zone; no
  runApp, no activity, so no window comes to the front). Dart registers the channel handler only
  once the database is open; until then the call sees "not implemented" and retries every 100 ms.
  The headless engine is destroyed after 120 s idle or when the app's engine attaches with no
  call in flight. In Dart, `DenHook` queues calls one at a time. After a write `clarityAutoBackup()`
  runs (it throttles itself, as on app open). Every call runs in a zone whose `print` goes
  nowhere, because the app's own code prints rows (deleteTransaction prints the deleted row).
- **Where the id lives.** `den_hook_ids.json` in the app documents directory next to `db.sqlite`:
  `{"v":1,"ids":{"<caller id>":{"pk":"<transactionPk>","removed"?:true}}}`, written to `.tmp`
  and renamed. The pk is a fresh UUID chosen and saved BEFORE the insert (`insert: false` keeps
  it; `createOrUpdateTransaction` then insertOrReplaces), so a retry after a crash between the two
  writes the same row, never a second. A removed id stays as a tombstone so a late retry cannot
  resurrect it. No schema, backup or Cashew-import change; a restored backup just leaves stale
  entries, which answer as "not saved" / `not_found`.
- **Matching.** `resolveDenHookCategory` feeds appLinks.dart's `getMainAndSubcategoryFromParams`
  (pk when the value is an existing pk, else the name) without a title, so it never falls back to
  title matching; then anything unresolved, a subcategory not under the named category, or
  category `"0"` (balance correction) is `bad_args`. Accounts: pk, else `getRelatingWallet`; left
  out = `selectedWalletPk` (what the add link uses), and that one is `default: true` in `accounts`.
- **Shapes.** `recent` is every paid row (not only hook rows), newest first; `month` counts rows by
  the money-summary rules above (paid, category != "0", no objective loan, type not credit/debt)
  and sums amounts as stored: no currency conversion (out of scope), `currency` is the default
  account's. `methodAdded` is `appLink`, an existing value.
- **Not verified (needs a phone):** the headless engine actually starting from a cold process and
  answering inside 10 s; plugins attaching without an activity; no window appearing; the UI
  refreshing while open; `getPackagesForUid`/`GET_SIGNING_CERTIFICATES` for the real den-app
  (package visibility is via `<queries>`); two engines briefly open on one database when the app
  opens while the headless engine is still alive (SQLite locking, not tested).

# pair-app (2026-11-20): what `check_pair_app.sh` pins

Run: `bash .den/checks/check_pair_app.sh` (a few minutes; most of it is `flutter build apk --debug`).
Every way of pairing ends in `redeemProvisionLink` (`lib/widgets/clarityProvision.dart`), the path a
clarity://provision link already took, so success and failure show the same messages.

- **Source:** `android.permission.CAMERA` in the manifest (plus `uses-feature camera required=false`);
  `mobile_scanner` (7.5.x, CameraX + ML Kit) in pubspec.yaml and pubspec.lock; `lib/pages/clarityPairPage.dart`
  titled "Pair with red" with a `MobileScanner(` and a plain message on `permissionDenied`; scan and type
  both pass `redeem: redeemProvisionLink`; one-tap paste via `Clipboard.getData`; `openClarityPairPage` from
  `accountAndBackup.dart` (the login button when not paired) and `onBoardingPage.dart` (last page, when not
  paired); handleProvisionLink still parses with `parseProvisionLink`, as does `lib/struct/clarityPairInput.dart`;
  no print/log of code, token or the raw text in the new files; `version: 5.6.0+420`.
- **Dart** (`dart/pair_app_test.dart`, >= 9): a typed bare code is normalised like red's `normalize_code`
  and redeems against `ClarityServer.kServerUrl`; a typed link uses its code and the default or its red
  `url=`; a scanned link redeems with its base URL; scanned non-Clarity text (a URL, a Wi-Fi QR, plain words)
  is refused as "Not a Clarity pairing code"; a clarity link pointing off red is "Pairing link not usable";
  the form's Pair, scan and paste buttons.
- **APK:** the debug APK carries libsqlite3.so for every ABI that ships libflutter.so, and asks for CAMERA.
- **Not verified (needs a phone):** the camera opening, the permission prompt and its denial screen, and a
  real QR being read off a screen; a real redeem against red from the new screen.
- check_den_hook.sh pins `5.6.0+419`, so it now fails on its version line only.

# pair-server (2026-11-20): what `check_pair_qr.py` pins

Run: `python3 .den/checks/check_pair_qr.py` (seconds). `clarity device pair NAME` gains `--qr` (draw the
clarity://provision link as a QR in the terminal) and `--qr-file PATH` (`.png` or `.svg`, mode 0600: it holds a
live code). Encoder: **segno 1.6.6** (pure Python, no deps), lazily imported in `server/clarity_server/qr.py`.

- **Decoded, not trusted:** the check carries its own QR reader (v1-10: finder/format bits, unmask, block
  de-interleave, Reed-Solomon recomputed, byte mode) and reads the terminal drawing, the PNG pixels and the SVG
  path back into modules; each must decode to exactly the printed (or JSON) link.
- **Unchanged without --qr:** the plain output must match the old three-part text with no block characters.
- **--json:** stdout is one JSON object with exactly `code`, `link`, `expires`; no drawing even with `--qr`.
- **Drawing:** half-blocks (two module rows per line), 4-module light quiet zone, ink where the code is light
  (right on dark terminals; on a tty colours are forced white-on-black, `NO_COLOR` turns that off); v6-M is 49x25.
- **Bad --qr-file** (wrong extension, missing directory) or missing segno: rc 2 *before* a code is minted.
- **segno in the venv:** `.den/server-requirements.txt` needs `segno==1.6.6` (managing agent). Until then the
  check installs it once into `~/.local/share/clarity/check-segno-1.6.6` and sets PYTHONPATH for bin/clarity only;
  `server/tests/test_qr.py` skips without segno.
- **Not verified (needs a phone):** a real camera reading the terminal drawing.

# clarity-favorites (2026-11-23): what `check_favorites.sh` pins

Contract: den-app `docs/MONEY.md`, "Stage 3 ... favorites, kept in Clarity (hook api 2, Clarity 5.7.0)", on
top of "The hook, as pinned (2026-11-20)". Nothing in either was renamed or reshaped.
Run: `bash .den/checks/check_favorites.sh` (about 8-12 minutes; most of it is the den-hook run's
`bin/release --dry-run`).

## Pins

- **Source:** `denHook.dart` dispatches `favorites`, `favorite_save`, `favorite_remove`, `suggestions`,
  `suggestion_dismiss` (to `struct/denFavorites.dart`); `kDenHookApi = 2`; `version: 5.7.0+421`;
  `schemaVersionGlobal = 48` and `budget/lib/database` byte-identical to 5.6.0 (`git diff b5917ba`); no
  change under `lib/pages`, `lib/widgets` or `AndroidManifest.xml` (nothing visible, no new component);
  `den_favorites` created with `CREATE TABLE IF NOT EXISTS`; `denFavorites.dart` neither prints nor logs and
  never writes Clarity's own tables; suggestions group in SQL; README describes api 2.
- **Dart** (`dart/favorites_test.dart`, >= 14 tests, real FinanceDatabase): hello api 2; a new favorite
  with no matches has `usual_amount: null, uses: 0, last_used_ms: null`; a known id replaces (Edit); the same
  category+subcategory+title (any case, surrounding spaces) answers the existing one, while another title
  or another subcategory is another favorite; `bad_args` for unknown category / subcategory / subcategory
  of another category / account, empty or blank title, no id, no category, non-bool income, bad
  `now_ms`/`limit`, with nothing saved and no category made; remove, then `not_found`; usual_amount =
  most frequent, ties to the most recent; suggestions need 3 rows, skip favorites, keeping one
  (favorite_save with its fields) removes it, removing the favorite brings the same key back; dismiss
  holds across new rows and a new DenHook; the order cases (below); 20,000 rows under 2 s each on the
  host; both backup directions (below); nothing printed.
- **api 1:** `check_den_hook.sh` is run from a patched copy in a temp dir, changed ONLY where the
  contract changes it: its version pins (`5.6.0+419` -> `5.7.0+421`, `clarity-5.6.0.apk` ->
  `clarity-5.7.0.apk`) and the hello test's `"api": 1` -> `"api": 2` (exactly 2 lines of
  `den_hook_test.dart`). Everything else, the JVM caller tests and the release APK (bin/release
  --dry-run with a throwaway key; check_startup's libsqlite3.so-per-ABI rule) runs as written. The
  protected original cannot pass as is: it already failed on main at `5.6.0+420`, and api 2 changes hello.

## Choices

- **Where they are kept: two plain SQLite tables inside db.sqlite**, `den_favorites(id PK, title,
  title_key, income, category_fk, sub_category_fk, wallet_fk, saved_ms)` and `den_dismissed(key PK,
  dismissed_ms)`, created with `CREATE TABLE IF NOT EXISTS` at the start of every api 2 call. Not drift
  tables, no schema step, `user_version` stays 48. Why: the backup to red is the whole file's bytes
  (`clarityAutoBackup` -> `getCurrentDBFileInfo`) and a restore replaces the file, so the tables travel
  both ways with no code in the backup path. A drift table would need schema 49, and 5.6.0 cannot open a
  file newer than its schema (README "Older Cashew versions"), which breaks the hard rule. The settings
  JSON (which does travel) was the other candidate; it lives in SharedPreferences and is copied into the
  file only before a backup, and SQL could not group against it. The side file `den_hook_ids.json` is
  not in the backup at all. Proven by tests: (a) a 5.7.0 file with favorites and a dismissal, copied and
  opened by `FinanceDatabase` exactly as 5.6.0 has it (lib/database unchanged, pinned), is user_version
  48, `integrity_check` ok, every row of transactions/categories/wallets/budgets/objectives identical,
  den tables still in the file, and back in 5.7.0 the favorite and the dismissal are there; (b) a 5.6.0
  file (no den tables, which is also what a Cashew import yields after drift's own migration) opened by
  5.7.0: favorites `[]`, suggestions found, a save works, those five tables byte-for-byte unchanged,
  still 48; (c) tables dropped under a live hook (a restore while open) are recreated, not an error.
  A failed `CREATE TABLE` touches nothing of 5.6.0's: there is no migration. Writes to these two tables
  are hand-written SQL in denFavorites.dart; transactions are never written by api 2.
- **Matching:** same `category_fk`, same `sub_category_fk` (NULL = NULL), and `lower(trim(name))` equal
  (trim of space, tab, CR, LF), computed in SQLite for both sides so they always agree. "Taxi to JHH" and
  "taxi to jhh " are one; "Taxi to JHH airport" is another; nothing is merged by similarity. Limit: SQLite's
  `lower()` folds ASCII only (Chinese titles have no case; "É"/"é" stay apart). Rows used: paid, category
  not "0", non-blank title. Account and income are not part of the match; a suggestion's title, income
  and account are those of its newest row.
- **Order:** per matching transaction, `closeness × day`: closeness = `max(0, 1 - d/120)` with d the
  minutes between its time of day and now's (wrapping midnight), so only ±2 h counts; day = 1 same
  weekday, 0.5 same kind of day (Mon-Fri vs Sat-Sun), 0 otherwise. Sorted by the sum, then uses, then
  last use (favorites with nothing then by newest saved). The sum means a habit entered often near now
  beats a rare one. Time of day uses now's UTC offset for the whole history (no DST in his zone; in a DST
  zone a summer row reads one hour off in winter). Tested: 4 weeks of taxi to JHH 08:00 Mon-Fri (20),
  taxi home 19:00 Mon-Sat (24), lunch 12:30 Mon-Fri (20), market Sunday 12:00 (4): Tue 08:00 -> taxi to
  JHH first, Tue 19:00 -> taxi home, Tue 12:30 -> lunch, Sunday 12:30 -> market, taxi home, lunch, taxi
  to JHH; 03:00 (nothing near) -> frequency.
- **Cost:** one `GROUP BY category, subcategory, key` over transactions with the score computed per row
  in SQL, then per shown group two small queries (latest row; usual amount `GROUP BY round(abs(amount),2)
  ORDER BY count DESC, last DESC`). No index added (that would change the file 5.6.0 opens, harmlessly,
  but it was not needed). Measured in the test, 20,000 generated rows, 500 titles, this build host:
  suggestions(limit 30) 182 ms, favorites(10) 60 ms. The bound asserted is 2 s, a 5x margin under 10 s.
- **Not verified (needs a phone):** the real timing on a mid-range phone; the five methods through the
  provider and a headless engine with Clarity closed (the same channel as api 1, but not run on a device);
  the backup actually uploaded to red carrying the tables and a restore from red bringing them back
  (proven on the file, not through the server); den-app's host and Money 1.1.0 against this build.
