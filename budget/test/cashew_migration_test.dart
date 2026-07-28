// Verifies that a database produced by Cashew opens in Clarity unchanged.
//
// Clarity tracks upstream Cashew's Play Store schema (v48), so a current
// Cashew backup (.sqlite) is byte-compatible: importing one is just a file
// copy followed by a normal open (older v46 backups are migrated — see
// restore_v48_test.dart). These tests exercise that path directly against
// the real schema, without the Flutter app or path_provider.
//
// Run with: flutter test test/cashew_migration_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

FinanceDatabase openDbFile(File file) =>
    FinanceDatabase(NativeDatabase(file, logStatements: false));

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('clarity_migration_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a fresh database is created at the schema version Cashew shipped', () async {
    final file = File('${tempDir.path}/db.sqlite');
    final db = openDbFile(file);

    // Forces onCreate to run.
    await db.getAllWallets();
    final version = await db.customSelect('PRAGMA user_version;').getSingle();

    expect(version.data['user_version'], schemaVersionGlobal);
    expect(schemaVersionGlobal, 48,
        reason: 'Changing the schema breaks Cashew backup compatibility');

    await db.close();
  });

  test('a Cashew-shaped database round-trips through an import', () async {
    // 1. Stand in for the user's existing Cashew database.
    final cashewFile = File('${tempDir.path}/cashew-backup.sqlite');
    final cashew = openDbFile(cashewFile);
    // Parts of the data layer route through the app-wide database handle.
    database = cashew;

    await cashew.createOrUpdateWallet(
      TransactionWallet(
        walletPk: '0',
        name: 'Checking',
        dateCreated: DateTime(2024, 1, 1),
        dateTimeModified: null,
        order: 0,
        currency: 'usd',
        decimals: 2,
        archived: false,
      ),
    );
    await cashew.createOrUpdateCategory(
      insert: true,
      updateSharedEntry: false,
      TransactionCategory(
        categoryPk: '0',
        name: 'Groceries',
        dateCreated: DateTime(2024, 1, 1),
        dateTimeModified: null,
        order: 0,
        income: false,
        methodAdded: MethodAdded.csv,
        archived: false,
      ),
    );
    // insert: true assigns fresh primary keys, so resolve the real one.
    final groceriesPk =
        (await cashew.getCategoryInstanceGivenName('Groceries')).categoryPk;
    await cashew.createOrUpdateTransaction(
      insert: true,
      updateSharedEntry: false,
      Transaction(
        transactionPk: '0',
        name: 'Weekly shop',
        amount: -42.5,
        note: '',
        categoryFk: groceriesPk,
        walletFk: '0',
        dateCreated: DateTime(2024, 6, 1),
        dateTimeModified: null,
        income: false,
        paid: true,
        skipPaid: false,
      ),
    );

    // Cashew stores app preferences inside the database so backups carry them.
    await cashew.createOrUpdateSettings(
      AppSetting(
        settingsPk: 0,
        settingsJSON: json.encode({
          'username': 'Existing User',
          'selectedWalletPk': '0',
          // A premium key Clarity no longer knows about; it must not break.
          'purchaseID': 'legacy-purchase-token',
        }),
        dateUpdated: DateTime(2024, 6, 1),
      ),
    );
    await cashew.close();

    // 2. Import == copy the file into place, then open it.
    final clarityFile = File('${tempDir.path}/db.sqlite');
    await clarityFile.writeAsBytes(await cashewFile.readAsBytes());
    final clarity = openDbFile(clarityFile);
    database = clarity;

    // 3. The user's data is intact.
    final transactions = await clarity.getAllTransactionsFromWallet('0');
    expect(transactions, hasLength(1));
    expect(transactions.single.name, 'Weekly shop');
    expect(transactions.single.amount, -42.5);

    expect((await clarity.getAllWallets()).single.name, 'Checking');
    expect((await clarity.getAllCategories()).single.name, 'Groceries');

    // 4. Preferences survive, including keys Clarity dropped.
    final restored =
        json.decode((await clarity.getSettings()).settingsJSON) as Map;
    expect(restored['username'], 'Existing User');
    expect(restored['purchaseID'], 'legacy-purchase-token');

    await clarity.close();
  });
}
