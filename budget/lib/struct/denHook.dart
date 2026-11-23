// The den-app hook, Dart side (Clarity 5.6.0; api 2 in 5.7.0). Contract: den-app docs/MONEY.md,
// "The hook, as pinned (2026-11-20)". Do not rename methods, keys or error codes.
//
// Android's DenHookProvider (content://com.clarity.finance.den) checks the caller, then hands
// {method, arg} to this file over the MethodChannel [kDenHookChannel]: to the running app's
// engine when Clarity is open (so its drift streams refresh at once), otherwise to a headless
// engine started on [denHookMain] (main.dart). Every write goes through the same
// FinanceDatabase.createOrUpdateTransaction / deleteTransaction the app's own screens use.
//
// The caller's id never touches the database schema: it lives in a side file,
// den_hook_ids.json next to db.sqlite ([DenHookFileIdStore]), mapping id -> transactionPk.
// The backup (db.sqlite) and the Cashew import do not see it.
//
// Nothing here prints amounts, titles or notes: only ids and error codes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart'
    show addAssociatedTitles, MainAndSubcategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/denFavorites.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/util/appLinks.dart'
    show getMainAndSubcategoryFromParams;
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/services.dart';

const String kDenHookChannel = "com.clarity.finance/den_hook";
// 2 since 5.7.0: favorites, favorite_save, favorite_remove, suggestions, suggestion_dismiss
// (denFavorites.dart). Everything of api 1 is unchanged.
const int kDenHookApi = 2;

class DenHookError implements Exception {
  final String code; // denied, bad_args, not_found, busy, failed
  final String message;
  DenHookError(this.code, this.message);
  Map<String, dynamic> toJson() =>
      {"ok": false, "error": code, "message": message};
  @override
  String toString() => "DenHookError($code)";
}

/// Where a caller's id is remembered: id -> {pk, removed}.
abstract class DenHookIdStore {
  Future<DenHookIdEntry?> get(String id);
  Future<void> put(String id, DenHookIdEntry entry);
  Future<String?> idForPk(String transactionPk);
}

class DenHookIdEntry {
  final String pk;
  final bool removed;
  DenHookIdEntry(this.pk, {this.removed = false});
  Map<String, dynamic> toJson() => {"pk": pk, if (removed) "removed": true};
  static DenHookIdEntry fromJson(dynamic j) =>
      DenHookIdEntry(j["pk"] as String, removed: j["removed"] == true);
}

class DenHookMemoryIdStore implements DenHookIdStore {
  final Map<String, DenHookIdEntry> ids = {};
  Future<DenHookIdEntry?> get(String id) async => ids[id];
  Future<void> put(String id, DenHookIdEntry e) async => ids[id] = e;
  Future<String?> idForPk(String pk) async {
    for (final e in ids.entries) {
      if (e.value.pk == pk && !e.value.removed) return e.key;
    }
    return null;
  }
}

/// den_hook_ids.json: {"v": 1, "ids": {"<caller id>": {"pk": "<transactionPk>"}}}.
/// Written to a temp file and renamed, so a crash never leaves half a file.
class DenHookFileIdStore implements DenHookIdStore {
  final File file;
  Map<String, DenHookIdEntry>? _cache;
  DenHookFileIdStore(this.file);

  Future<Map<String, DenHookIdEntry>> _load() async {
    if (_cache != null) return _cache!;
    final Map<String, DenHookIdEntry> ids = {};
    if (await file.exists()) {
      final dynamic j = json.decode(await file.readAsString());
      (j["ids"] as Map).forEach((k, v) => ids[k as String] = DenHookIdEntry.fromJson(v));
    }
    return _cache = ids;
  }

  Future<DenHookIdEntry?> get(String id) async => (await _load())[id];

  Future<void> put(String id, DenHookIdEntry e) async {
    final ids = await _load();
    ids[id] = e;
    final tmp = File(file.path + ".tmp");
    await tmp.writeAsString(json.encode({
      "v": 1,
      "ids": ids.map((k, v) => MapEntry(k, v.toJson())),
    }), flush: true);
    await tmp.rename(file.path);
  }

  Future<String?> idForPk(String pk) async {
    for (final e in (await _load()).entries) {
      if (e.value.pk == pk && !e.value.removed) return e.key;
    }
    return null;
  }
}

class DenHook {
  final DenHookIdStore ids;

  /// Clarity's versionName and versionCode, for `hello`.
  final String Function() version;
  final int Function() versionCode;

  /// Runs after a write: the app passes clarityAutoBackup (it throttles itself).
  final void Function()? afterWrite;

  /// api 2: favorites and suggestions.
  final DenFavorites favorites = DenFavorites();

  DenHook({
    required this.ids,
    required this.version,
    required this.versionCode,
    this.afterWrite,
  });

  Future<void> _queue = Future.value();

  /// One call at a time: drift and SQLite get one writer, and a repeated `add` sees the first.
  Future<Map<String, dynamic>> call(String method, String? arg) {
    final c = Completer<Map<String, dynamic>>();
    // The app's own code prints rows (deleteTransaction prints the deleted row, amount and
    // all), and a release build's print reaches logcat: inside a hook call it goes nowhere.
    final Zone outer = Zone.current;
    _queue = _queue.then((_) async {
      try {
        c.complete(await runZoned(() => _dispatch(method, arg),
            zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {})));
      } on DenHookError catch (e) {
        c.complete(e.toJson());
      } catch (e) {
        outer.print("den hook: $method failed (${e.runtimeType})");
        c.complete({
          "ok": false,
          "error": "failed",
          "message": "Clarity could not do that.",
        });
      }
    });
    return c.future;
  }

  Future<String> callJson(String method, String? arg) async =>
      json.encode(await call(method, arg));

  Future<Map<String, dynamic>> _dispatch(String method, String? arg) async {
    Map<String, dynamic> req = {};
    if (arg != null && arg.trim().isNotEmpty) {
      dynamic j;
      try {
        j = json.decode(arg);
      } catch (_) {
        throw DenHookError("bad_args", "The request is not JSON.");
      }
      if (j is! Map) throw DenHookError("bad_args", "The request must be a JSON object.");
      req = Map<String, dynamic>.from(j);
    }
    switch (method) {
      case "hello":
        return {"ok": true, "version": version(), "version_code": versionCode(), "api": kDenHookApi};
      case "add":
        return _add(req);
      case "remove":
        return _remove(req);
      case "recent":
        return _recent(req);
      case "categories":
        return _categories();
      case "accounts":
        return _accounts();
      case "month":
        return _month(req);
      // api 2 (5.7.0): favorites and suggestions, kept in db.sqlite by denFavorites.dart.
      case "favorites":
        return favorites.list(req);
      case "favorite_save":
        return favorites.save(req, afterWrite);
      case "favorite_remove":
        return favorites.remove(req, afterWrite);
      case "suggestions":
        return favorites.suggestions(req);
      case "suggestion_dismiss":
        return favorites.dismiss(req, afterWrite);
    }
    throw DenHookError("bad_args", "Unknown method.");
  }

  // ---- add / remove ----

  String _id(Map<String, dynamic> req) {
    final id = req["id"];
    if (id is! String || id.trim().isEmpty || id.length > 200) {
      throw DenHookError("bad_args", "id must be a non-empty string.");
    }
    return id;
  }

  String? _optString(Map<String, dynamic> req, String key) {
    final v = req[key];
    if (v == null) return null;
    if (v is String) return v;
    if (v is num && (key == "category" || key == "subcategory" || key == "account")) {
      return v.toString();
    }
    throw DenHookError("bad_args", "$key must be a string.");
  }

  Future<Map<String, dynamic>> _add(Map<String, dynamic> req) async {
    final String id = _id(req);
    final dynamic amountRaw = req["amount"];
    if (amountRaw is! num || !amountRaw.isFinite || amountRaw <= 0) {
      throw DenHookError("bad_args", "amount must be a positive number.");
    }
    final income = req["income"] ?? false;
    if (income is! bool) throw DenHookError("bad_args", "income must be true or false.");
    final dateMs = req["date_ms"];
    if (dateMs != null && dateMs is! int) {
      throw DenHookError("bad_args", "date_ms must be whole epoch milliseconds.");
    }
    final String title = _optString(req, "title") ?? "";
    final String note = _optString(req, "note") ?? "";
    final String? category = _optString(req, "category");
    final String? subcategory = _optString(req, "subcategory");
    final String? account = _optString(req, "account");

    // A repeat: answer the saved row, save nothing.
    final DenHookIdEntry? seen = await ids.get(id);
    if (seen != null) {
      if (seen.removed) {
        throw DenHookError("bad_args", "This id was removed; use a new id.");
      }
      final Transaction? saved = await database.tryGetTransactionFromPk(seen.pk);
      if (saved != null) return {"ok": true, "transaction": await _tx(saved, id: id)};
      // Mapped but not written (a crash between the two): write it now under the same pk.
    }

    if (category == null || category.trim().isEmpty) {
      throw DenHookError("bad_args", "category is required.");
    }
    final MainAndSubcategory cats = await resolveDenHookCategory(category, subcategory);
    final TransactionWallet wallet = await resolveDenHookAccount(account);

    // The pk is chosen first and remembered before the write, so a retry after a crash
    // lands on the same row instead of adding a second one.
    final String pk = seen?.pk ?? uuid.v4();
    if (seen == null) await ids.put(id, DenHookIdEntry(pk));

    final double amount = amountRaw.toDouble();
    await database.createOrUpdateTransaction(
      Transaction(
        transactionPk: pk,
        name: title,
        amount: denHookStoredAmount(amount, income),
        note: note,
        categoryFk: cats.main!.categoryPk,
        subCategoryFk: cats.sub?.categoryPk,
        walletFk: wallet.walletPk,
        dateCreated: dateMs == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(dateMs as int),
        income: income,
        paid: true,
        skipPaid: false,
        methodAdded: MethodAdded.appLink,
      ),
      // insert:false keeps our pk; createOrUpdateTransaction then inserts it (insertOrReplace).
      insert: false,
    );
    if (title.trim() != "") {
      try {
        await addAssociatedTitles(title, cats.main!);
      } catch (_) {}
    }
    afterWrite?.call();
    final Transaction saved = await database.getTransactionFromPk(pk);
    return {"ok": true, "transaction": await _tx(saved, id: id)};
  }

  Future<Map<String, dynamic>> _remove(Map<String, dynamic> req) async {
    final String id = _id(req);
    final DenHookIdEntry? seen = await ids.get(id);
    if (seen == null || seen.removed) {
      throw DenHookError("not_found", "No transaction came in through den with this id.");
    }
    final Transaction? row = await database.tryGetTransactionFromPk(seen.pk);
    await ids.put(id, DenHookIdEntry(seen.pk, removed: true));
    if (row == null) {
      throw DenHookError("not_found", "That transaction is no longer in Clarity.");
    }
    await database.deleteTransaction(seen.pk);
    afterWrite?.call();
    return {"ok": true};
  }

  // ---- reads ----

  Future<Map<String, dynamic>> _recent(Map<String, dynamic> req) async {
    final limitRaw = req["limit"] ?? 20;
    if (limitRaw is! int) throw DenHookError("bad_args", "limit must be a whole number.");
    final int limit = limitRaw.clamp(1, 100);
    final rows = await (database.select(database.transactions)
          ..where((t) => t.paid.equals(true))
          ..orderBy([
            (t) => OrderingTerm.desc(t.dateCreated),
            (t) => OrderingTerm.desc(t.dateTimeModified),
          ])
          ..limit(limit))
        .get();
    final out = <Map<String, dynamic>>[];
    for (final t in rows) {
      out.add(await _tx(t, id: await ids.idForPk(t.transactionPk)));
    }
    return {"ok": true, "transactions": out};
  }

  Future<Map<String, dynamic>> _categories() async {
    final all = await (database.select(database.categories)
          ..where((c) => c.archived.equals(false))
          ..orderBy([(c) => OrderingTerm.asc(c.order)]))
        .get();
    final out = <Map<String, dynamic>>[];
    for (final c in all.where((c) => c.mainCategoryPk == null)) {
      out.add({"pk": c.categoryPk, "name": c.name, "income": c.income});
      for (final s in all.where((s) => s.mainCategoryPk == c.categoryPk)) {
        out.add({"pk": s.categoryPk, "name": s.name, "income": s.income, "parent_pk": c.categoryPk});
      }
    }
    return {"ok": true, "categories": out};
  }

  Future<Map<String, dynamic>> _accounts() async {
    final String def = await _defaultWalletPk();
    final all = await (database.select(database.wallets)
          ..where((w) => w.archived.equals(false))
          ..orderBy([(w) => OrderingTerm.asc(w.order)]))
        .get();
    return {
      "ok": true,
      "accounts": [
        for (final w in all)
          {"pk": w.walletPk, "name": w.name, "currency": w.currency, "default": w.walletPk == def}
      ],
    };
  }

  Future<Map<String, dynamic>> _month(Map<String, dynamic> req) async {
    final m = req["month"];
    final DateTime now = DateTime.now();
    int year = now.year, month = now.month;
    if (m != null) {
      final match = m is String ? RegExp(r'^(\d{4})-(\d{2})$').firstMatch(m) : null;
      if (match == null) throw DenHookError("bad_args", "month must be YYYY-MM.");
      year = int.parse(match.group(1)!);
      month = int.parse(match.group(2)!);
      if (month < 1 || month > 12) throw DenHookError("bad_args", "month must be YYYY-MM.");
    }
    // DateTime(...) is the phone's own zone.
    final DateTime start = DateTime(year, month, 1);
    final DateTime end = DateTime(year, month + 1, 1);
    final rows = await (database.select(database.transactions)
          ..where((t) =>
              t.paid.equals(true) &
              t.categoryFk.equals("0").not() &
              t.objectiveLoanFk.isNull() &
              (t.type.isNull() |
                  t.type.isNotIn([
                    TransactionSpecialType.credit.index,
                    TransactionSpecialType.debt.index,
                  ])) &
              t.dateCreated.isBiggerOrEqualValue(start) &
              t.dateCreated.isSmallerThanValue(end)))
        .get();
    double spent = 0, incomeTotal = 0;
    final Map<String, double> byCat = {};
    for (final t in rows) {
      if (t.income) {
        incomeTotal += t.amount;
      } else {
        spent += -t.amount;
        byCat[t.categoryFk] = (byCat[t.categoryFk] ?? 0) + -t.amount;
      }
    }
    final List<Map<String, dynamic>> cats = [];
    for (final e in byCat.entries) {
      final c = await database.getCategoryInstanceOrNull(e.key);
      cats.add({"pk": e.key, "name": c?.name ?? "", "spent": _round(e.value)});
    }
    cats.sort((a, b) => (b["spent"] as double).compareTo(a["spent"] as double));
    final wallet = await database.getWalletInstanceOrNull(await _defaultWalletPk());
    return {
      "ok": true,
      "month": "${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}",
      "spent": _round(spent),
      "income": _round(incomeTotal),
      "by_category": cats,
      "currency": wallet?.currency,
    };
  }

  // ---- shapes ----

  Future<Map<String, dynamic>> _tx(Transaction t, {String? id}) async {
    final c = await database.getCategoryInstanceOrNull(t.categoryFk);
    final s = t.subCategoryFk == null
        ? null
        : await database.getCategoryInstanceOrNull(t.subCategoryFk!);
    final w = await database.getWalletInstanceOrNull(t.walletFk);
    return {
      "id": id,
      "pk": t.transactionPk,
      "amount": t.amount.abs(),
      "income": t.income,
      "title": t.name,
      "note": t.note,
      "date_ms": t.dateCreated.millisecondsSinceEpoch,
      "category": {"pk": t.categoryFk, "name": c?.name ?? ""},
      if (s != null) "subcategory": {"pk": s.categoryPk, "name": s.name},
      "account": {"pk": t.walletFk, "name": w?.name ?? "", "currency": w?.currency},
    };
  }
}

double _round(double v) => (v * 100).roundToDouble() / 100;

/// Clarity's sign rule: an expense is stored negative, income positive (see NOTES.md).
double denHookStoredAmount(double positiveAmount, bool income) =>
    income ? positiveAmount.abs() : -positiveAmount.abs();

Future<String> _defaultWalletPk() async {
  final String? selected = appStateSettings["selectedWalletPk"]?.toString();
  if (selected != null && await database.getWalletInstanceOrNull(selected) != null) {
    return selected;
  }
  return "0";
}

/// The category the hook means, matched as the add-transaction app link matches
/// (appLinks.dart getMainAndSubcategoryFromParams: a pk first, then the name exactly, then
/// ignoring case, then a substring). Unlike the link, an unknown name is never ignored and
/// never prompts: it is bad_args.
Future<MainAndSubcategory> resolveDenHookCategory(String category, String? subcategory) async {
  final Map<String, String?> params = {};
  final bool categoryIsPk = (await database.getCategoryInstanceOrNull(category)) != null;
  params[categoryIsPk ? "categoryPk" : "category"] = category;
  if (subcategory != null && subcategory.trim().isNotEmpty) {
    final bool subIsPk = (await database.getCategoryInstanceOrNull(subcategory)) != null;
    params[subIsPk ? "subcategoryPk" : "subcategory"] = subcategory;
  } else {
    subcategory = null;
  }
  final MainAndSubcategory found = await getMainAndSubcategoryFromParams(params);
  if (found.main == null || found.main!.categoryPk == "0") {
    throw DenHookError("bad_args", "Clarity has no such category.");
  }
  if (subcategory != null && found.sub == null) {
    throw DenHookError("bad_args", "Clarity has no such subcategory in that category.");
  }
  // The link lets a subcategory pull in its own parent; the hook asked for this category.
  final TransactionCategory? asked = categoryIsPk
      ? await database.getCategoryInstanceOrNull(category)
      : await database.getRelatingCategory(category, onlySubCategories: false);
  if (asked == null || asked.categoryPk != found.main!.categoryPk) {
    throw DenHookError("bad_args", "That subcategory is not in that category.");
  }
  return found;
}

/// The account: a pk, or a name matched like the link's getWalletFromParams; left out,
/// Clarity's default (the selected account). Unknown is bad_args.
Future<TransactionWallet> resolveDenHookAccount(String? account) async {
  if (account == null || account.trim().isEmpty) {
    final w = await database.getWalletInstanceOrNull(await _defaultWalletPk());
    if (w == null) throw DenHookError("failed", "Clarity has no account yet.");
    return w;
  }
  final w = await database.getWalletInstanceOrNull(account) ??
      await database.getRelatingWallet(account);
  if (w == null) throw DenHookError("bad_args", "Clarity has no such account.");
  return w;
}

/// Answers the provider's calls on [messenger]: "call" {method, arg} -> the JSON string.
/// Registered only once the database is open, so until then the provider sees
/// "not implemented" and waits.
void registerDenHookChannel(BinaryMessenger messenger, DenHook hook) {
  MethodChannel(kDenHookChannel, const StandardMethodCodec(), messenger)
      .setMethodCallHandler((MethodCall call) async {
    if (call.method != "call") throw MissingPluginException();
    final Map args = call.arguments as Map;
    return hook.callJson(args["method"] as String, args["arg"] as String?);
  });
}
