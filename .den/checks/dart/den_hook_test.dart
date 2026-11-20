// Acceptance: den-hook (Clarity 5.6.0). The Dart side of the den-app hook, every method, over a
// real (in-memory) Clarity database through the app's own write path.
// Contract: den-app docs/MONEY.md "The hook, as pinned (2026-11-20)".
// Copied into budget/test/den_accept/den_hook/ by check_den_hook.sh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/denHook.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late FinanceDatabase db;
late DenHook hook;
late DenHookMemoryIdStore ids;
int writes = 0;

Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? req]) async {
  // Through the JSON string, as the provider sees it.
  final String out = await hook.callJson(method, req == null ? null : json.encode(req));
  return json.decode(out) as Map<String, dynamic>;
}

Future<int> rowCount() async =>
    (await db.customSelect('SELECT COUNT(*) c FROM transactions').getSingle()).data['c'] as int;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    db = FinanceDatabase(NativeDatabase.memory());
    database = db;
    appStateSettings = {
      "sharedBudgets": false,
      "selectedWalletPk": "0",
      "autoAddAssociatedTitles": false,
    };
    await db.customStatement('''
      INSERT INTO wallets (wallet_pk, name, date_created, "order", currency, decimals) VALUES
        ('0', 'Cash', 1700000000, 0, 'cny', 2), ('w2', 'Bank Card', 1700000000, 1, 'cny', 2);
    ''');
    await db.customStatement('''
      INSERT INTO categories (category_pk, name, date_created, "order", income, main_category_pk) VALUES
        ('food', 'Dining', 1700000000, 0, 0, NULL),
        ('coffee', 'Coffee', 1700000000, 0, 0, 'food'),
        ('groc', 'Groceries', 1700000000, 1, 0, NULL),
        ('pay', 'Salary', 1700000000, 2, 1, NULL);
    ''');
    // A row the user typed in Clarity itself, not through the hook.
    await db.customStatement('''
      INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, wallet_fk, date_created, paid, income)
      VALUES ('own1', 'typed in Clarity', -10.0, '', 'groc', '0', ${DateTime(2026, 10, 3).millisecondsSinceEpoch ~/ 1000}, 1, 0);
    ''');
    ids = DenHookMemoryIdStore();
    writes = 0;
    hook = DenHook(
      ids: ids,
      version: () => "5.6.0",
      versionCode: () => 419,
      afterWrite: () => writes++,
    );
  });

  tearDown(() async => db.close());

  test("hello answers api 1 and the version", () async {
    final r = await call("hello", {});
    expect(r, {"ok": true, "version": "5.6.0", "version_code": 419, "api": 1});
  });

  test("add twice with one id saves one row and answers the same transaction", () async {
    final before = await rowCount();
    final req = {"id": "u-1", "amount": 35, "title": "Lunch", "category": "Dining", "date_ms": DateTime(2026, 11, 5, 12).millisecondsSinceEpoch};
    final a = await call("add", req);
    final b = await call("add", req);
    expect(a["ok"], true, reason: "$a");
    expect(b, a);
    expect(await rowCount(), before + 1);
    final t = a["transaction"] as Map;
    expect(t["id"], "u-1");
    expect(t["amount"], 35);
    expect(t["income"], false);
    expect(t["title"], "Lunch");
    expect(t["category"], {"pk": "food", "name": "Dining"});
    expect(t["account"], {"pk": "0", "name": "Cash", "currency": "cny"});
    expect(t["date_ms"], DateTime(2026, 11, 5, 12).millisecondsSinceEpoch);
    expect(writes, 1, reason: "the repeat writes nothing");
  });

  test("the sign rule: an expense is stored negative, income positive", () async {
    final e = await call("add", {"id": "e", "amount": 12.5, "category": "groc"});
    final i = await call("add", {"id": "i", "amount": 1000, "income": true, "category": "pay"});
    expect(e["ok"], true, reason: "$e");
    expect(i["ok"], true, reason: "$i");
    final te = await db.getTransactionFromPk(e["transaction"]["pk"]);
    final ti = await db.getTransactionFromPk(i["transaction"]["pk"]);
    expect(te.amount, -12.5);
    expect(te.income, false);
    expect(ti.amount, 1000);
    expect(ti.income, true);
    expect(e["transaction"]["amount"], 12.5, reason: "the hook answers a positive amount");
    expect(denHookStoredAmount(3, false), -3);
    expect(denHookStoredAmount(3, true), 3);
  });

  test("names match as the add link matches; subcategory and account by name or pk", () async {
    final r = await call("add", {"id": "n", "amount": 4, "category": "dining", "subcategory": "COFFEE", "account": "bank"});
    expect(r["ok"], true, reason: "$r");
    expect(r["transaction"]["category"]["pk"], "food");
    expect(r["transaction"]["subcategory"], {"pk": "coffee", "name": "Coffee"});
    expect(r["transaction"]["account"]["pk"], "w2");
    final p = await call("add", {"id": "p", "amount": 4, "category": "groc", "account": "w2"});
    expect(p["transaction"]["category"]["pk"], "groc");
    expect(p["transaction"]["account"]["pk"], "w2");
  });

  test("unknown category, subcategory or account is bad_args and saves nothing", () async {
    final before = await rowCount();
    for (final req in [
      {"id": "x1", "amount": 5, "category": "Spaceships"},
      {"id": "x2", "amount": 5, "category": "Dining", "subcategory": "Tea"},
      {"id": "x3", "amount": 5, "category": "Groceries", "subcategory": "Coffee"},
      {"id": "x4", "amount": 5, "category": "Dining", "account": "Swiss vault"},
      {"id": "x5", "amount": 5},
      {"id": "x6", "amount": -5, "category": "Dining"},
      {"amount": 5, "category": "Dining"},
    ]) {
      final r = await call("add", req);
      expect(r["ok"], false, reason: "$req");
      expect(r["error"], "bad_args", reason: "$req");
      expect(r["message"], isA<String>());
    }
    expect(await rowCount(), before);
    expect((await db.getAllCategories(includeSubCategories: true)).length, 4,
        reason: "never a silently created category");
  });

  test("remove works only for a row that came in through the hook", () async {
    final own = await call("remove", {"id": "own1"});
    expect(own["ok"], false);
    expect(own["error"], "not_found");
    expect(await db.tryGetTransactionFromPk("own1"), isNotNull);

    final a = await call("add", {"id": "r1", "amount": 7, "category": "Dining"});
    final pk = a["transaction"]["pk"];
    expect(await call("remove", {"id": "r1"}), {"ok": true});
    expect(await db.tryGetTransactionFromPk(pk), isNull);
    final logs = await db.customSelect("SELECT COUNT(*) c FROM delete_logs WHERE entry_pk = ?",
        variables: [Variable.withString(pk)]).getSingle();
    expect(logs.data['c'], 1, reason: "the delete goes through deleteTransaction's change log");
    expect((await call("remove", {"id": "r1"}))["error"], "not_found");
    final again = await call("add", {"id": "r1", "amount": 7, "category": "Dining"});
    expect(again["ok"], false, reason: "a late retry never brings a removed row back");
  });

  test("recent reads what add wrote, newest first, with the caller's id", () async {
    await call("add", {"id": "old", "amount": 1, "category": "Dining", "date_ms": DateTime(2026, 11, 1).millisecondsSinceEpoch});
    await call("add", {"id": "new", "amount": 2, "category": "Dining", "date_ms": DateTime(2026, 11, 9).millisecondsSinceEpoch});
    final r = await call("recent", {"limit": 2});
    expect(r["ok"], true);
    final list = r["transactions"] as List;
    expect(list.map((t) => t["id"]), ["new", "old"]);
    final all = (await call("recent"))["transactions"] as List;
    expect(all.length, 3);
    expect(all.last["pk"], "own1");
    expect(all.last["id"], isNull);
    expect(((await call("recent", {"limit": 1000}))["transactions"] as List).length, 3);
  });

  test("month sums what add wrote in the phone's zone", () async {
    await call("add", {"id": "m1", "amount": 30, "category": "Dining", "date_ms": DateTime(2026, 11, 1, 0, 30).millisecondsSinceEpoch});
    await call("add", {"id": "m2", "amount": 20.25, "category": "Groceries", "date_ms": DateTime(2026, 11, 30, 23, 0).millisecondsSinceEpoch});
    await call("add", {"id": "m3", "amount": 500, "income": true, "category": "Salary", "date_ms": DateTime(2026, 11, 15).millisecondsSinceEpoch});
    await call("add", {"id": "m4", "amount": 99, "category": "Dining", "date_ms": DateTime(2026, 12, 1, 0, 1).millisecondsSinceEpoch});
    final r = await call("month", {"month": "2026-11"});
    expect(r["ok"], true, reason: "$r");
    expect(r["month"], "2026-11");
    expect(r["spent"], closeTo(50.25, 0.005));
    expect(r["income"], closeTo(500, 0.005));
    expect(r["currency"], "cny");
    expect(r["by_category"], [
      {"pk": "food", "name": "Dining", "spent": 30.0},
      {"pk": "groc", "name": "Groceries", "spent": 20.25},
    ]);
    final oct = await call("month", {"month": "2026-10"});
    expect(oct["spent"], closeTo(10, 0.005));
    expect((await call("month", {"month": "2026-13"}))["error"], "bad_args");
    final now = await call("month", {});
    final n = DateTime.now();
    expect(now["month"], "${n.year}-${n.month.toString().padLeft(2, '0')}");
  });

  test("categories and accounts in Clarity's order", () async {
    final c = await call("categories", {});
    expect(c["categories"], [
      {"pk": "food", "name": "Dining", "income": false},
      {"pk": "coffee", "name": "Coffee", "income": false, "parent_pk": "food"},
      {"pk": "groc", "name": "Groceries", "income": false},
      {"pk": "pay", "name": "Salary", "income": true},
    ]);
    final a = await call("accounts", {});
    expect(a["accounts"], [
      {"pk": "0", "name": "Cash", "currency": "cny", "default": true},
      {"pk": "w2", "name": "Bank Card", "currency": "cny", "default": false},
    ]);
  });

  test("nothing the app prints during a call escapes (no amounts or titles to logcat)", () async {
    final printed = <String>[];
    await runZoned(() async {
      await call("add", {"id": "q", "amount": 987.65, "title": "SecretTitle", "category": "Dining"});
      await call("remove", {"id": "q"});
      await call("add", {"id": "q2", "amount": 1, "category": "Nowhere"});
    }, zoneSpecification: ZoneSpecification(print: (_, __, ___, line) => printed.add(line)));
    expect(printed.join("\n"), isNot(contains("987.65")));
    expect(printed.join("\n"), isNot(contains("SecretTitle")));
  });

  test("bad JSON and unknown methods are bad_args", () async {
    expect(json.decode(await hook.callJson("add", "{nope"))["error"], "bad_args");
    expect((await call("launch_missiles", {}))["error"], "bad_args");
  });

  test("the id file survives a restart and is not the database", () async {
    final dir = Directory.systemTemp.createTempSync("den_hook_ids");
    try {
      final f = File("${dir.path}/den_hook_ids.json");
      hook = DenHook(ids: DenHookFileIdStore(f), version: () => "", versionCode: () => 0);
      final a = await call("add", {"id": "f1", "amount": 3, "category": "Dining"});
      hook = DenHook(ids: DenHookFileIdStore(f), version: () => "", versionCode: () => 0);
      final b = await call("add", {"id": "f1", "amount": 3, "category": "Dining"});
      expect(b, a);
      expect(json.decode(f.readAsStringSync())["ids"]["f1"]["pk"], a["transaction"]["pk"]);
      expect(await call("remove", {"id": "f1"}), {"ok": true});
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
