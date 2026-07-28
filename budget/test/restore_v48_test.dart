// Covers restoring backups from both schema generations of Cashew:
//
//  * v46 — what the public Cashew source drop creates. Opening one in
//    Clarity (schema 48) must run the reconstructed 46->48 migration.
//  * v48 — what the current Play Store Cashew exports. Opening one must be
//    a plain open with no migration at all.
//
// The v46 fixture is built from the exact DDL a fresh v46 build generates.
// Optionally, point BACKUP at a real Cashew export to smoke-test it too:
//   BACKUP=path/to/cashew-db-v48-....sql flutter test test/restore_v48_test.dart

import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

const _v46Ddl = '''
CREATE TABLE "app_settings" ("settings_pk" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, "settings_j_s_o_n" TEXT NOT NULL, "date_updated" INTEGER NOT NULL);
CREATE TABLE "associated_titles" ("associated_title_pk" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "title" TEXT NOT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "order" INTEGER NOT NULL, "is_exact_match" INTEGER NOT NULL DEFAULT 0 CHECK ("is_exact_match" IN (0, 1)), PRIMARY KEY ("associated_title_pk"));
CREATE TABLE "budgets" ("budget_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "amount" REAL NOT NULL, "colour" TEXT NULL, "start_date" INTEGER NOT NULL, "end_date" INTEGER NOT NULL, "wallet_fks" TEXT NULL, "category_fks" TEXT NULL, "category_fks_exclude" TEXT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "added_transactions_only" INTEGER NOT NULL DEFAULT 0 CHECK ("added_transactions_only" IN (0, 1)), "period_length" INTEGER NOT NULL, "reoccurrence" INTEGER NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "pinned" INTEGER NOT NULL DEFAULT 0 CHECK ("pinned" IN (0, 1)), "order" INTEGER NOT NULL, "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "budget_transaction_filters" TEXT NULL DEFAULT NULL, "member_transaction_filters" TEXT NULL DEFAULT NULL, "shared_key" TEXT NULL, "shared_owner_member" INTEGER NULL, "shared_date_updated" INTEGER NULL, "shared_members" TEXT NULL, "shared_all_members_ever" TEXT NULL, "is_absolute_spending_limit" INTEGER NOT NULL DEFAULT 0 CHECK ("is_absolute_spending_limit" IN (0, 1)), PRIMARY KEY ("budget_pk"));
CREATE TABLE "categories" ("category_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "colour" TEXT NULL, "icon_name" TEXT NULL, "emoji_icon_name" TEXT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "order" INTEGER NOT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "method_added" INTEGER NULL, "main_category_pk" TEXT NULL DEFAULT NULL REFERENCES categories (category_pk), PRIMARY KEY ("category_pk"));
CREATE TABLE "category_budget_limits" ("category_limit_pk" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "budget_fk" TEXT NOT NULL REFERENCES budgets (budget_pk), "amount" REAL NOT NULL, "date_time_modified" INTEGER NULL, "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), PRIMARY KEY ("category_limit_pk"));
CREATE TABLE "delete_logs" ("delete_log_pk" TEXT NOT NULL, "entry_pk" TEXT NOT NULL, "type" INTEGER NOT NULL, "date_time_modified" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("delete_log_pk"));
CREATE TABLE "objectives" ("objective_pk" TEXT NOT NULL, "type" INTEGER NOT NULL DEFAULT 0, "name" TEXT NOT NULL, "amount" REAL NOT NULL, "order" INTEGER NOT NULL, "colour" TEXT NULL, "date_created" INTEGER NOT NULL, "end_date" INTEGER NULL, "date_time_modified" INTEGER NULL, "icon_name" TEXT NULL, "emoji_icon_name" TEXT NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "pinned" INTEGER NOT NULL DEFAULT 1 CHECK ("pinned" IN (0, 1)), "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), PRIMARY KEY ("objective_pk"));
CREATE TABLE "scanner_templates" ("scanner_template_pk" TEXT NOT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "template_name" TEXT NOT NULL, "contains" TEXT NOT NULL, "title_transaction_before" TEXT NOT NULL, "title_transaction_after" TEXT NOT NULL, "amount_transaction_before" TEXT NOT NULL, "amount_transaction_after" TEXT NOT NULL, "default_category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "ignore" INTEGER NOT NULL DEFAULT 0 CHECK ("ignore" IN (0, 1)), PRIMARY KEY ("scanner_template_pk"));
CREATE TABLE "transactions" ("transaction_pk" TEXT NOT NULL, "paired_transaction_fk" TEXT NULL DEFAULT NULL REFERENCES transactions (transaction_pk), "name" TEXT NOT NULL, "amount" REAL NOT NULL, "note" TEXT NOT NULL, "category_fk" TEXT NOT NULL REFERENCES categories (category_pk), "sub_category_fk" TEXT NULL DEFAULT NULL REFERENCES categories (category_pk), "wallet_fk" TEXT NOT NULL DEFAULT '0' REFERENCES wallets (wallet_pk), "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "original_date_due" INTEGER NULL, "income" INTEGER NOT NULL DEFAULT 0 CHECK ("income" IN (0, 1)), "period_length" INTEGER NULL, "reoccurrence" INTEGER NULL, "end_date" INTEGER NULL, "upcoming_transaction_notification" INTEGER NULL DEFAULT 1 CHECK ("upcoming_transaction_notification" IN (0, 1)), "type" INTEGER NULL, "paid" INTEGER NOT NULL DEFAULT 0 CHECK ("paid" IN (0, 1)), "created_another_future_transaction" INTEGER NULL DEFAULT 0 CHECK ("created_another_future_transaction" IN (0, 1)), "skip_paid" INTEGER NOT NULL DEFAULT 0 CHECK ("skip_paid" IN (0, 1)), "method_added" INTEGER NULL, "transaction_owner_email" TEXT NULL, "transaction_original_owner_email" TEXT NULL, "shared_key" TEXT NULL, "shared_old_key" TEXT NULL, "shared_status" INTEGER NULL, "shared_date_updated" INTEGER NULL, "shared_reference_budget_pk" TEXT NULL, "objective_fk" TEXT NULL REFERENCES objectives (objective_pk), "objective_loan_fk" TEXT NULL REFERENCES objectives (objective_pk), "budget_fks_exclude" TEXT NULL, PRIMARY KEY ("transaction_pk"));
CREATE TABLE "wallets" ("wallet_pk" TEXT NOT NULL, "name" TEXT NOT NULL, "colour" TEXT NULL, "icon_name" TEXT NULL, "date_created" INTEGER NOT NULL, "date_time_modified" INTEGER NULL, "order" INTEGER NOT NULL, "currency" TEXT NULL, "currency_format" TEXT NULL, "decimals" INTEGER NOT NULL DEFAULT 2, "home_page_widget_display" TEXT NULL DEFAULT NULL, PRIMARY KEY ("wallet_pk"));
''';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('clarity_restore_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a v46 Cashew database migrates to v48 with data intact', () async {
    final dbFile = File('${tempDir.path}/db.sqlite');
    final fixture = raw.sqlite3.open(dbFile.path);
    for (final stmt in _v46Ddl.split(';\n')) {
      if (stmt.trim().isNotEmpty) fixture.execute(stmt);
    }
    fixture.execute('''
      INSERT INTO wallets (wallet_pk, name, date_created, "order") VALUES ('0', 'Checking', 1700000000, 0);
      INSERT INTO categories (category_pk, name, date_created, "order") VALUES ('c1', 'Groceries', 1700000000, 0);
      INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, paid) VALUES ('t1', 'Weekly shop', -42.5, '', 'c1', '0', 1700000000, 1);
      PRAGMA user_version = 46;
    ''');
    fixture.dispose();

    final db = FinanceDatabase(NativeDatabase(dbFile, logStatements: false));
    database = db;

    final version = await db.customSelect('PRAGMA user_version;').getSingle();
    expect(version.data['user_version'], 48);

    final wallets = await db.getAllWallets();
    expect(wallets.single.name, 'Checking');
    expect(wallets.single.archived, false);
    expect((await db.getAllCategories()).single.archived, false);

    final transactions = await db.getAllTransactionsFromWallet('0');
    expect(transactions.single.amount, -42.5);

    // The v48 tables exist and are queryable.
    final tagCount =
        await db.customSelect('SELECT COUNT(*) c FROM tags;').getSingle();
    expect(tagCount.data['c'], 0);
    await db
        .customSelect('SELECT COUNT(*) c FROM transaction_to_tag_links;')
        .getSingle();

    await db.close();
  });

  test(
    'a real v48 Cashew export opens without migration and keeps its data',
    () async {
      final backupPath = Platform.environment['BACKUP']!;
      final dbFile = File('${tempDir.path}/db.sqlite');
      dbFile.writeAsBytesSync(File(backupPath).readAsBytesSync());

      final db = FinanceDatabase(NativeDatabase(dbFile, logStatements: false));
      database = db;

      final version = await db.customSelect('PRAGMA user_version;').getSingle();
      expect(version.data['user_version'], 48);

      expect(await db.getAllWallets(), isNotEmpty);
      expect(await db.getAllCategories(), isNotEmpty);
      final count = await db
          .customSelect('SELECT COUNT(*) c FROM transactions;')
          .getSingle();
      expect(count.data['c'], greaterThan(0));
      // Settings parse (carries user preferences through the restore).
      await db.getSettings();

      await db.close();
    },
    skip: Platform.environment['BACKUP'] == null
        ? 'set BACKUP=<path to a real Cashew v48 export>'
        : null,
  );
}
