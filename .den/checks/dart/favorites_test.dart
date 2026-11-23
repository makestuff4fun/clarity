// Acceptance: clarity-favorites (Clarity 5.7.0, hook api 2). The Dart side of favorites,
// favorite_save, favorite_remove, suggestions, suggestion_dismiss over a real Clarity database.
// Contract: den-app docs/MONEY.md "Stage 3 ... favorites, kept in Clarity (hook api 2, Clarity 5.7.0)".
// Copied into budget/test/den_accept/favorites/ by check_favorites.sh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/denHook.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late FinanceDatabase db;
late DenHook hook;
int writes = 0;

Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? req]) async {
  final String out = await hook.callJson(method, req == null ? null : json.encode(req));
  return json.decode(out) as Map<String, dynamic>;
}

int _txn = 0;
Future<void> tx(String title, double amount, DateTime when,
    {String cat = "ha", String? sub = "transport", String wallet = "0", bool income = false}) async {
  _txn++;
  await db.customStatement(
      'INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, sub_category_fk, wallet_fk, date_created, paid, income) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)',
      ["t$_txn", title, income ? amount : -amount, "", cat, sub, wallet, when.millisecondsSinceEpoch ~/ 1000, income ? 1 : 0]);
}

Future<void> seed() async {
  await db.customStatement('''
    INSERT INTO wallets (wallet_pk, name, date_created, "order", currency, decimals) VALUES
      ('0', 'Cash', 1700000000, 0, 'cny', 2), ('w2', 'Bank Card', 1700000000, 1, 'cny', 2);
  ''');
  await db.customStatement('''
    INSERT INTO categories (category_pk, name, date_created, "order", income, main_category_pk) VALUES
      ('ha', 'Human Archive', 1700000000, 0, 0, NULL),
      ('transport', 'Transportation', 1700000000, 0, 0, 'ha'),
      ('food', 'Dining', 1700000000, 1, 0, NULL),
      ('fun', 'Fun', 1700000000, 2, 0, NULL),
      ('pay', 'Salary', 1700000000, 3, 1, NULL);
  ''');
}

Future<void> openDb(FinanceDatabase d) async {
  db = d;
  database = d;
  hook = DenHook(ids: DenHookMemoryIdStore(), version: () => "5.7.0", versionCode: () => 421,
      afterWrite: () => writes++);
}

// A Monday, then every weekday of four weeks: taxi to JHH at 08:00 (20x), taxi home at 19:00
// (24x: four extra Saturdays), lunch at 12:30 Mon-Fri (20x).
final DateTime monday = DateTime(2026, 10, 5);
Future<void> habits() async {
  for (int w = 0; w < 4; w++) {
    for (int d = 0; d < 5; d++) {
      final day = monday.add(Duration(days: w * 7 + d));
      await tx("Taxi to JHH", 25, DateTime(day.year, day.month, day.day, 8, 0));
      await tx("Taxi home", 30, DateTime(day.year, day.month, day.day, 19, 0));
      await tx("Lunch", 35, DateTime(day.year, day.month, day.day, 12, 30), cat: "food", sub: null);
    }
    final sat = monday.add(Duration(days: w * 7 + 5));
    await tx("Taxi home", 30, DateTime(sat.year, sat.month, sat.day, 19, 0));
    final sun = monday.add(Duration(days: w * 7 + 6));
    await tx("Brunch market", 60, DateTime(sun.year, sun.month, sun.day, 12, 0), cat: "fun", sub: null);
  }
}

List<String> titles(List l) => [for (final e in l) e["title"] as String];
int at(DateTime t) => t.millisecondsSinceEpoch;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
    appStateSettings = {"sharedBudgets": false, "selectedWalletPk": "0", "autoAddAssociatedTitles": false};
    await openDb(FinanceDatabase(NativeDatabase.memory()));
    await seed();
    writes = 0;
  });

  tearDown(() async => db.close());

  test("hello answers api 2", () async {
    expect(await call("hello", {}), {"ok": true, "version": "5.7.0", "version_code": 421, "api": 2});
  });

  test("favorite_save creates; with no matching transaction usual_amount is null and uses 0", () async {
    final r = await call("favorite_save",
        {"id": "f1", "category": "Human Archive", "subcategory": "Transportation", "title": "Taxi to JHH", "account": "Bank Card"});
    expect(r["ok"], true);
    expect(r["favorite"], {
      "id": "f1",
      "title": "Taxi to JHH",
      "income": false,
      "category": {"pk": "ha", "name": "Human Archive"},
      "subcategory": {"pk": "transport", "name": "Transportation"},
      "account": {"pk": "w2", "name": "Bank Card", "currency": "cny"},
      "usual_amount": null,
      "uses": 0,
      "last_used_ms": null,
    });
    expect(writes, 1);
    final l = await call("favorites", {});
    expect(l["favorites"], [r["favorite"]]);
  });

  test("favorite_save with a known id replaces it (Edit)", () async {
    await call("favorite_save", {"id": "f1", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"});
    final r = await call("favorite_save", {"id": "f1", "category": "Dining", "title": "Lunch", "account": "w2"});
    expect(r["favorite"]["title"], "Lunch");
    expect(r["favorite"]["category"], {"pk": "food", "name": "Dining"});
    expect(r["favorite"].containsKey("subcategory"), false);
    final l = (await call("favorites", {}))["favorites"] as List;
    expect(l.length, 1);
    expect(l.single["id"], "f1");
    expect(l.single["title"], "Lunch");
  });

  test("a second favorite with the same category, subcategory and title answers the existing one", () async {
    final a = await call("favorite_save", {"id": "f1", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"});
    final b = await call("favorite_save", {"id": "f2", "category": "Human Archive", "subcategory": "Transportation", "title": "  taxi to jhh "});
    expect(b, a);
    expect(((await call("favorites", {}))["favorites"] as List).length, 1);
    // A different title is a different favorite: nothing is merged by similarity.
    final c = await call("favorite_save", {"id": "f3", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH airport"});
    expect(c["favorite"]["id"], "f3");
    // Another subcategory (none) is another favorite too.
    final d = await call("favorite_save", {"id": "f4", "category": "ha", "title": "Taxi to JHH"});
    expect(d["favorite"]["id"], "f4");
    expect(((await call("favorites", {}))["favorites"] as List).length, 3);
  });

  test("bad_args: unknown category, subcategory or account, empty title, no id; nothing saved", () async {
    for (final req in [
      {"id": "x", "category": "Nope", "title": "a"},
      {"id": "x", "category": "ha", "subcategory": "Nope", "title": "a"},
      {"id": "x", "category": "food", "subcategory": "transport", "title": "a"},
      {"id": "x", "category": "ha", "account": "Nope", "title": "a"},
      {"id": "x", "category": "ha", "title": ""},
      {"id": "x", "category": "ha", "title": "   "},
      {"id": "x", "category": "ha"},
      {"category": "ha", "title": "a"},
      {"id": "x", "title": "a"},
      {"id": "x", "category": "ha", "title": "a", "income": "yes"},
    ]) {
      final r = await call("favorite_save", req);
      expect(r["ok"], false, reason: json.encode(req));
      expect(r["error"], "bad_args", reason: json.encode(req));
    }
    expect((await call("favorites", {}))["favorites"], []);
    final cats = await db.customSelect("SELECT COUNT(*) n FROM categories").getSingle();
    expect(cats.read<int>("n"), 5);
    expect((await call("favorites", {"now_ms": "noon"}))["error"], "bad_args");
    expect((await call("suggestions", {"limit": "ten"}))["error"], "bad_args");
  });

  test("favorite_remove removes; an unknown id is not_found", () async {
    await call("favorite_save", {"id": "f1", "category": "ha", "title": "Taxi"});
    expect(await call("favorite_remove", {"id": "f1"}), {"ok": true});
    expect((await call("favorite_remove", {"id": "f1"}))["error"], "not_found");
    expect((await call("favorite_remove", {"id": "never"}))["error"], "not_found");
    expect((await call("favorite_remove", {}))["error"], "bad_args");
    expect((await call("favorites", {}))["favorites"], []);
  });

  test("usual_amount is the most frequent amount (ties: most recent), uses counts matches", () async {
    final d = DateTime(2026, 11, 2, 8);
    await tx("Taxi to JHH", 25, d);
    await tx("taxi to jhh ", 25, d.add(const Duration(days: 1)));
    await tx("TAXI TO JHH", 31, d.add(const Duration(days: 2)));
    await tx("Taxi to JHH", 31, d.add(const Duration(days: 3)));
    await tx("Taxi to JHH airport", 99, d.add(const Duration(days: 4))); // another title
    await tx("Taxi to JHH", 99, d.add(const Duration(days: 5)), sub: null); // another subcategory
    await call("favorite_save", {"id": "f1", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"});
    var f = ((await call("favorites", {}))["favorites"] as List).single;
    expect(f["uses"], 4);
    expect(f["usual_amount"], 31.0); // 25 and 31 twice each: 31 was used last
    expect(f["last_used_ms"], at(d.add(const Duration(days: 3))));
    await tx("Taxi to JHH", 25, d.add(const Duration(days: 6)));
    f = ((await call("favorites", {}))["favorites"] as List).single;
    expect(f["usual_amount"], 25.0); // now 25 three times
    expect(f["uses"], 5);
  });

  test("a suggestion needs 3 matching transactions and is never already a favorite", () async {
    final d = DateTime(2026, 11, 2, 9);
    await tx("Coffee", 12, d, cat: "food", sub: null);
    await tx(" coffee", 12, d.add(const Duration(days: 1)), cat: "food", sub: null);
    expect((await call("suggestions", {}))["suggestions"], []);
    await tx("COFFEE ", 15, d.add(const Duration(days: 2)), cat: "food", sub: null);
    final s = ((await call("suggestions", {}))["suggestions"] as List).single;
    expect(s["title"], "COFFEE");
    expect(s["uses"], 3);
    expect(s["usual_amount"], 12.0);
    expect(s["last_used_ms"], at(d.add(const Duration(days: 2))));
    expect(s["category"], {"pk": "food", "name": "Dining"});
    expect(s.containsKey("subcategory"), false);
    expect(s["account"], {"pk": "0", "name": "Cash", "currency": "cny"});
    expect(s["income"], false);
    expect(s["key"], isA<String>());
    // Keeping it is favorite_save with its fields: it leaves suggestions.
    final k = await call("favorite_save",
        {"id": "kept", "title": s["title"], "category": s["category"]["pk"], "account": s["account"]["pk"], "income": s["income"]});
    expect(k["favorite"]["uses"], 3);
    expect((await call("suggestions", {}))["suggestions"], []);
    // Removing the favorite brings the group back as a suggestion, with the same key.
    await call("favorite_remove", {"id": "kept"});
    expect(((await call("suggestions", {}))["suggestions"] as List).single["key"], s["key"]);
  });

  test("suggestion_dismiss is for good: new rows and a new DenHook do not bring it back", () async {
    await habits();
    final before = (await call("suggestions", {}))["suggestions"] as List;
    expect(before.length, 4);
    final lunch = before.firstWhere((s) => s["title"] == "Lunch");
    expect(await call("suggestion_dismiss", {"key": lunch["key"]}), {"ok": true});
    expect(await call("suggestion_dismiss", {"key": lunch["key"]}), {"ok": true});
    await tx("Lunch", 35, DateTime(2026, 11, 3, 12, 30), cat: "food", sub: null);
    await openDb(db);
    final after = (await call("suggestions", {}))["suggestions"] as List;
    expect(titles(after).contains("Lunch"), false);
    expect(after.length, 3);
    expect((await call("suggestion_dismiss", {"key": "not a key"}))["error"], "bad_args");
    expect((await call("suggestion_dismiss", {}))["error"], "bad_args");
    final lim = (await call("suggestions", {"limit": 2}))["suggestions"] as List;
    expect(lim.length, 2);
  });

  test("order: the morning and evening taxi swap between 08:00 and 19:00; a weekday lunch drops on Sunday", () async {
    await habits();
    for (final f in [
      {"id": "a", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"},
      {"id": "b", "category": "ha", "subcategory": "transport", "title": "Taxi home"},
      {"id": "c", "category": "food", "title": "Lunch"},
      {"id": "d", "category": "fun", "title": "Brunch market"},
    ]) {
      await call("favorite_save", f);
    }
    final tue8 = DateTime(2026, 11, 3, 8, 0), tue19 = DateTime(2026, 11, 3, 19, 0);
    final tue1230 = DateTime(2026, 11, 3, 12, 30), sun1230 = DateTime(2026, 11, 8, 12, 30);
    expect(tue8.weekday, DateTime.tuesday);
    expect(sun1230.weekday, DateTime.sunday);
    Future<List<String>> favs(DateTime t) async =>
        titles((await call("favorites", {"now_ms": at(t)}))["favorites"] as List);
    expect((await favs(tue8)).first, "Taxi to JHH");
    expect((await favs(tue19)).first, "Taxi home");
    expect((await favs(tue1230)).first, "Lunch");
    final sun = await favs(sun1230);
    expect(sun.first, "Brunch market");
    expect(sun.indexOf("Lunch"), greaterThan(0));
    // At an hour with no habit near it, frequency decides: taxi home (24) first.
    expect((await favs(DateTime(2026, 11, 3, 3, 0))).first, "Taxi home");
    // The same order for suggestions (remove the favorites first).
    for (final id in ["a", "b", "c", "d"]) {
      await call("favorite_remove", {"id": id});
    }
    Future<List<String>> sugg(DateTime t) async =>
        titles((await call("suggestions", {"now_ms": at(t)}))["suggestions"] as List);
    expect((await sugg(tue8)).first, "Taxi to JHH");
    expect((await sugg(tue19)).first, "Taxi home");
    expect((await sugg(tue1230)).first, "Lunch");
    expect((await sugg(sun1230)).first, "Brunch market");
    // Sunday: no habit near 12:30 but the market, then frequency (24, 20, 20), then recency.
    expect(await sugg(sun1230), ["Brunch market", "Taxi home", "Lunch", "Taxi to JHH"]);
  });

  test("20,000 transactions: suggestions and favorites answer well inside the 10 s bound", () async {
    final int base = DateTime(2025, 1, 1).millisecondsSinceEpoch ~/ 1000;
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
      INSERT INTO transactions (transaction_pk, name, amount, note, category_fk, sub_category_fk, wallet_fk, date_created, paid, income)
      SELECT 'g' || i, 'item ' || (i % 500), -1.0 - (i % 37), '', CASE i % 3 WHEN 0 THEN 'ha' WHEN 1 THEN 'food' ELSE 'fun' END,
             CASE i % 3 WHEN 0 THEN 'transport' ELSE NULL END, '0', $base + i * 1700, 1, 0 FROM n
    ''');
    final n = await db.customSelect("SELECT COUNT(*) n FROM transactions").getSingle();
    expect(n.read<int>("n"), 20000);
    for (int i = 0; i < 10; i++) {
      await call("favorite_save", {"id": "f$i", "category": "food", "title": "item ${i * 3 + 1}"});
    }
    final sw = Stopwatch()..start();
    final s = await call("suggestions", {"limit": 30});
    final sMs = sw.elapsedMilliseconds;
    sw.reset();
    final f = await call("favorites", {});
    final fMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print("MEASURED 20000 rows: suggestions(limit 30) ${sMs} ms, favorites(10) ${fMs} ms");
    expect((s["suggestions"] as List).length, 30);
    expect((f["favorites"] as List).length, 10);
    expect(((f["favorites"] as List).first["uses"] as int) > 3, true);
    // A host is faster than a mid-range phone: demand a 5x margin under the 10 s bound.
    expect(sMs, lessThan(2000));
    expect(fMs, lessThan(2000));
  });

  // ---- backups: the db.sqlite file is the backup (getCurrentDBFileInfo) ----

  Future<String> snapshot(FinanceDatabase d) async {
    final out = <String>[];
    for (final t in ["transactions", "categories", "wallets", "budgets", "objectives"]) {
      final rows = await d.customSelect("SELECT * FROM $t ORDER BY 1").get();
      out.add("$t:${json.encode([for (final r in rows) r.data])}");
    }
    return out.join("\n");
  }

  Future<int> userVersion(FinanceDatabase d) async =>
      (await d.customSelect("PRAGMA user_version").getSingle()).data.values.first as int;

  Future<List<String>> denTables(FinanceDatabase d) async => [
        for (final r in await d
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'den_%' ORDER BY name")
            .get())
          r.read<String>("name")
      ];

  test("a 5.7.0 backup restores in 5.6.0: schema 48, every table readable, favorites kept in the file", () async {
    final dir = Directory.systemTemp.createTempSync("fav_backup");
    try {
      await db.close();
      final f57 = File("${dir.path}/db.sqlite");
      await openDb(FinanceDatabase(NativeDatabase(f57)));
      await seed();
      await habits();
      await call("favorite_save", {"id": "f1", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"});
      final s = ((await call("suggestions", {}))["suggestions"] as List).first;
      await call("suggestion_dismiss", {"key": s["key"]});
      final before = await snapshot(db);
      await db.close();
      // The backup is the file's bytes; 5.6.0 restores it by replacing its db.sqlite and opening it
      // with the same FinanceDatabase (lib/database is unchanged since 5.6.0, see check_favorites.sh).
      final f56 = File("${dir.path}/restored-in-560.sqlite");
      f56.writeAsBytesSync(f57.readAsBytesSync());
      db = FinanceDatabase(NativeDatabase(f56));
      database = db;
      expect(await userVersion(db), 48);
      expect(await snapshot(db), before);
      expect((await db.getAllWallets()).length, 2);
      expect((await db.select(db.categories).get()).length, 5);
      expect((await db.customSelect("PRAGMA integrity_check").getSingle()).data.values.first, "ok");
      expect(await denTables(db), ["den_dismissed", "den_favorites"]);
      // ... and when 5.6.0 backs that file up again and 5.7.0 restores it, the favorites are back.
      await openDb(db);
      final fav = ((await call("favorites", {}))["favorites"] as List).single;
      expect(fav["id"], "f1");
      expect(titles((await call("suggestions", {}))["suggestions"] as List).contains(s["title"]), false);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test("a 5.6.0 backup (or a Cashew import) restores in 5.7.0: no den tables yet, data untouched", () async {
    final dir = Directory.systemTemp.createTempSync("fav_backup");
    try {
      await db.close();
      // A 5.6.0 database file: FinanceDatabase as 5.6.0 has it, never touched by the api 2 code.
      final f56 = File("${dir.path}/db.sqlite");
      db = FinanceDatabase(NativeDatabase(f56));
      database = db;
      await seed();
      await habits();
      expect(await denTables(db), []);
      final before = await snapshot(db);
      await db.close();
      final f57 = File("${dir.path}/restored-in-570.sqlite");
      f57.writeAsBytesSync(f56.readAsBytesSync());
      await openDb(FinanceDatabase(NativeDatabase(f57)));
      expect(await userVersion(db), 48);
      expect((await call("favorites", {}))["favorites"], []);
      expect(((await call("suggestions", {}))["suggestions"] as List).length, 4);
      final r = await call("favorite_save", {"id": "f1", "category": "food", "title": "lunch"});
      expect(r["favorite"]["uses"], 20);
      expect(r["favorite"]["usual_amount"], 35.0);
      expect(await denTables(db), ["den_dismissed", "den_favorites"]);
      // The upgrade wrote nothing to transactions, categories, wallets, budgets or objectives.
      expect(await snapshot(db), before);
      expect(await userVersion(db), 48);
      // A restore while the hook is alive (tables gone from the new file) is not an error.
      await db.customStatement("DROP TABLE den_favorites");
      await db.customStatement("DROP TABLE den_dismissed");
      expect((await call("favorites", {}))["favorites"], []);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test("api 2 prints nothing (no titles or amounts to logcat)", () async {
    await habits();
    final printed = <String>[];
    await runZonedPrint(printed, () async {
      await call("favorite_save", {"id": "f1", "category": "ha", "subcategory": "transport", "title": "Taxi to JHH"});
      await call("favorites", {});
      final s = (await call("suggestions", {}))["suggestions"] as List;
      await call("suggestion_dismiss", {"key": s.first["key"]});
      await call("favorite_remove", {"id": "f1"});
      await call("favorite_save", {"id": "x", "category": "Nope", "title": "Secret"});
    });
    expect(printed, []);
  });
}

Future<void> runZonedPrint(List<String> sink, Future<void> Function() body) =>
    Zone.current.fork(specification: ZoneSpecification(print: (_, __, ___, line) => sink.add(line))).run(body);
