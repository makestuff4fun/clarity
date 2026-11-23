// The den-app hook, api 2: favorites and suggestions (Clarity 5.7.0). Contract: den-app
// docs/MONEY.md, "Stage 3 ... favorites, kept in Clarity (hook api 2, Clarity 5.7.0)".
// Do not rename methods, keys or error codes.
//
// WHERE IT IS KEPT. Two plain SQLite tables inside db.sqlite, created with CREATE TABLE IF NOT
// EXISTS on every call: den_favorites and den_dismissed. They are NOT drift tables and the drift
// schema stays 48 (user_version untouched), so:
//  - the backup (the whole db.sqlite file, getCurrentDBFileInfo) carries them to red;
//  - 5.6.0 opening a 5.7.0 backup sees user_version 48, runs no migration and never reads two
//    tables it does not know (and keeps them in the file, so they survive a 5.6.0 round trip);
//  - a 5.6.0 backup or a Cashew import has no such tables: the first call creates them empty.
//
// MATCHING. A transaction matches a favorite or a suggestion group when its category_fk and
// sub_category_fk are the same and lower(trim(name)) is the same: case and surrounding
// whitespace are ignored ("Taxi to JHH" = "taxi to jhh "); different titles are never merged.
//
// ORDER. score = sum over matching transactions of closeness(hour) * day(weekday), where
// closeness = max(0, 1 - minutes between the two times of day / 120) (so only +-2 h counts) and
// day = 1 same weekday, 0.5 same kind of day (Mon-Fri vs Sat-Sun), 0 otherwise. Sorted by score,
// then uses (overall frequency), then last_used_ms (recency).
//
// All grouping is SQL (one GROUP BY over transactions); Dart only filters the groups.
// Nothing here prints amounts, titles or notes.
import 'dart:convert';

import 'package:budget/database/tables.dart';
import 'package:budget/pages/addTransactionPage.dart' show MainAndSubcategory;
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/denHook.dart';
import 'package:drift/drift.dart' hide Column;

const int kDenSuggestionMinUses = 3;
const int kDenCloseMinutes = 120;

const String _ws = "char(32,9,10,13)";
String _keyOf(String expr) => "lower(trim($expr, $_ws))";

// Rows a favorite or suggestion can learn from: paid, a real category (not "0", the balance
// correction), with a title.
const String _usable = "t.paid = 1 AND t.category_fk != '0' AND trim(t.name, $_ws) != ''";

// Per transaction: (category, subcategory, key, date, score). p = (offset s, now minute, now dow).
const String _scored = """
p(off, nm, dw) AS (SELECT ?, ?, ?),
x AS (
  SELECT t.category_fk AS c, t.sub_category_fk AS s, ${"lower(trim(t.name, $_ws))"} AS k,
         t.date_created AS dc,
         max(0.0, 1.0 - min(abs(((t.date_created + p.off) % 86400) / 60 - p.nm),
                            1440 - abs(((t.date_created + p.off) % 86400) / 60 - p.nm)) / $kDenCloseMinutes.0)
         * (CASE WHEN ((t.date_created + p.off) / 86400 + 4) % 7 = p.dw THEN 1.0
                 WHEN ((((t.date_created + p.off) / 86400 + 4) % 7) IN (0, 6)) = (p.dw IN (0, 6)) THEN 0.5
                 ELSE 0.0 END) AS sc
  FROM transactions t, p
  WHERE $_usable
)""";

const String _ddl1 = """
CREATE TABLE IF NOT EXISTS den_favorites (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  title_key TEXT NOT NULL,
  income INTEGER NOT NULL,
  category_fk TEXT NOT NULL,
  sub_category_fk TEXT,
  wallet_fk TEXT,
  saved_ms INTEGER NOT NULL
)""";
const String _ddl2 = """
CREATE TABLE IF NOT EXISTS den_dismissed (
  key TEXT NOT NULL PRIMARY KEY,
  dismissed_ms INTEGER NOT NULL
)""";

/// The opaque, stable key of a group: base64url of the JSON [category, subcategory, title key].
String denSuggestionKey(String c, String? s, String k) =>
    base64Url.encode(utf8.encode(json.encode([c, s, k])));

class _Now {
  final int off, minute, dow;
  _Now(this.off, this.minute, this.dow);
  List<Variable> get vars => [Variable.withInt(off), Variable.withInt(minute), Variable.withInt(dow)];
}

class _Group {
  final String c;
  final String? s;
  final String k;
  final int uses;
  final int? last; // seconds
  final double score;
  _Group(this.c, this.s, this.k, this.uses, this.last, this.score);
}

class DenFavorites {
  Future<void> _ensure() async {
    await database.customStatement(_ddl1);
    await database.customStatement(_ddl2);
  }

  _Now _now(Map<String, dynamic> req) {
    final raw = req["now_ms"];
    if (raw != null && raw is! int) throw DenHookError("bad_args", "now_ms must be whole epoch milliseconds.");
    // DateTime.fromMillisecondsSinceEpoch is the phone's own zone.
    final DateTime now = raw == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(raw as int);
    return _Now(now.timeZoneOffset.inSeconds, now.hour * 60 + now.minute, now.weekday % 7);
  }

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
    if (v is num && key != "title") return v.toString();
    throw DenHookError("bad_args", "$key must be a string.");
  }

  // ---- favorites ----

  Future<Map<String, dynamic>> list(Map<String, dynamic> req) async {
    final _Now now = _now(req);
    await _ensure();
    final rows = await database.customSelect("""
      WITH $_scored
      SELECT f.id AS id, COUNT(x.dc) AS uses, MAX(x.dc) AS last, COALESCE(SUM(x.sc), 0.0) AS score,
             f.saved_ms AS saved
      FROM den_favorites f LEFT JOIN x
        ON x.c = f.category_fk AND x.s IS f.sub_category_fk AND x.k = f.title_key
      GROUP BY f.id
      ORDER BY score DESC, uses DESC, last DESC, saved DESC, f.id
    """, variables: now.vars).get();
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final fav = await _favorite(r.read<String>("id"));
      if (fav != null) out.add(fav);
    }
    return {"ok": true, "favorites": out};
  }

  Future<Map<String, dynamic>?> _favorite(String id) async {
    final f = await database.customSelect(
        "SELECT * FROM den_favorites WHERE id = ?", variables: [Variable.withString(id)]).getSingleOrNull();
    if (f == null) return null;
    final String c = f.read<String>("category_fk");
    final String? s = f.readNullable<String>("sub_category_fk");
    final String? w = f.readNullable<String>("wallet_fk");
    final stats = await _stats(c, s, f.read<String>("title_key"));
    return {
      "id": id,
      "title": f.read<String>("title"),
      "income": f.read<int>("income") == 1,
      ...await _cats(c, s),
      if (w != null) "account": await _account(w),
      "usual_amount": stats.usual,
      "uses": stats.uses,
      "last_used_ms": stats.lastMs,
    };
  }

  Future<Map<String, dynamic>> save(Map<String, dynamic> req, void Function()? afterWrite) async {
    final String id = _id(req);
    final String title = (_optString(req, "title") ?? "").trim();
    if (title.isEmpty) throw DenHookError("bad_args", "title is required.");
    if (title.length > 500) throw DenHookError("bad_args", "title is too long.");
    final String? category = _optString(req, "category");
    if (category == null || category.trim().isEmpty) throw DenHookError("bad_args", "category is required.");
    final MainAndSubcategory cats = await resolveDenHookCategory(category, _optString(req, "subcategory"));
    final String? account = _optString(req, "account");
    final TransactionWallet? wallet =
        account == null || account.trim().isEmpty ? null : await resolveDenHookAccount(account);
    final income = req["income"] ?? cats.main!.income;
    if (income is! bool) throw DenHookError("bad_args", "income must be true or false.");
    await _ensure();

    final String c = cats.main!.categoryPk;
    final String? s = cats.sub?.categoryPk;
    final String key = (await database.customSelect("SELECT ${_keyOf("?")} AS k",
            variables: [Variable.withString(title)]).getSingle())
        .read<String>("k");
    // Same category, subcategory and title as another favorite: that one is the answer.
    final same = await database.customSelect(
        "SELECT id FROM den_favorites WHERE category_fk = ? AND sub_category_fk IS ? AND title_key = ? AND id != ? LIMIT 1",
        variables: [
          Variable.withString(c),
          Variable(s),
          Variable.withString(key),
          Variable.withString(id),
        ]).getSingleOrNull();
    if (same != null) {
      return {"ok": true, "favorite": await _favorite(same.read<String>("id"))};
    }
    // A known id is replaced (Edit), a new one inserted.
    await database.customStatement(
        "INSERT OR REPLACE INTO den_favorites (id, title, title_key, income, category_fk, sub_category_fk, wallet_fk, saved_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [id, title, key, income ? 1 : 0, c, s, wallet?.walletPk, DateTime.now().millisecondsSinceEpoch]);
    afterWrite?.call();
    return {"ok": true, "favorite": await _favorite(id)};
  }

  Future<Map<String, dynamic>> remove(Map<String, dynamic> req, void Function()? afterWrite) async {
    final String id = _id(req);
    await _ensure();
    final n = await database.customUpdate("DELETE FROM den_favorites WHERE id = ?",
        variables: [Variable.withString(id)], updateKind: UpdateKind.delete);
    if (n == 0) throw DenHookError("not_found", "No favorite has this id.");
    afterWrite?.call();
    return {"ok": true};
  }

  // ---- suggestions ----

  Future<Map<String, dynamic>> suggestions(Map<String, dynamic> req) async {
    final _Now now = _now(req);
    final limitRaw = req["limit"] ?? 10;
    if (limitRaw is! int) throw DenHookError("bad_args", "limit must be a whole number.");
    final int limit = limitRaw.clamp(1, 30);
    await _ensure();
    final rows = await database.customSelect("""
      WITH $_scored
      SELECT c, s, k, COUNT(*) AS uses, MAX(dc) AS last, SUM(sc) AS score
      FROM x
      WHERE NOT EXISTS (SELECT 1 FROM den_favorites f
                        WHERE f.category_fk = x.c AND f.sub_category_fk IS x.s AND f.title_key = x.k)
      GROUP BY c, s, k
      HAVING COUNT(*) >= $kDenSuggestionMinUses
      ORDER BY score DESC, uses DESC, last DESC
    """, variables: now.vars).get();
    final Set<String> dismissed = {
      for (final r in await database.customSelect("SELECT key FROM den_dismissed").get())
        r.read<String>("key")
    };
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (out.length >= limit) break;
      final g = _Group(r.read<String>("c"), r.readNullable<String>("s"), r.read<String>("k"),
          r.read<int>("uses"), r.readNullable<int>("last"), r.read<double>("score"));
      final String key = denSuggestionKey(g.c, g.s, g.k);
      if (dismissed.contains(key)) continue;
      out.add(await _suggestion(g, key));
    }
    return {"ok": true, "suggestions": out};
  }

  Future<Map<String, dynamic>> _suggestion(_Group g, String key) async {
    // Title, income and account as he last entered them.
    final latest = await database.customSelect(
        "SELECT t.name AS name, t.income AS income, t.wallet_fk AS w FROM transactions t WHERE ${_match()} ORDER BY t.date_created DESC LIMIT 1",
        variables: _matchVars(g.c, g.s, g.k)).getSingle();
    final stats = await _stats(g.c, g.s, g.k);
    return {
      "key": key,
      "title": latest.read<String>("name").trim(),
      "income": latest.read<int>("income") == 1,
      ...await _cats(g.c, g.s),
      "account": await _account(latest.read<String>("w")),
      "usual_amount": stats.usual,
      "uses": stats.uses,
      "last_used_ms": stats.lastMs,
    };
  }

  Future<Map<String, dynamic>> dismiss(Map<String, dynamic> req, void Function()? afterWrite) async {
    final key = req["key"];
    bool valid = false;
    if (key is String && key.length <= 2000) {
      try {
        final d = json.decode(utf8.decode(base64Url.decode(key)));
        valid = d is List && d.length == 3 && d[0] is String && d[2] is String;
      } catch (_) {}
    }
    if (!valid) throw DenHookError("bad_args", "key must be a suggestion's key.");
    await _ensure();
    await database.customStatement("INSERT OR IGNORE INTO den_dismissed (key, dismissed_ms) VALUES (?, ?)",
        [key, DateTime.now().millisecondsSinceEpoch]);
    afterWrite?.call();
    return {"ok": true};
  }

  // ---- shared ----

  String _match() =>
      "t.category_fk = ? AND t.sub_category_fk IS ? AND ${_keyOf("t.name")} = ? AND $_usable";
  List<Variable> _matchVars(String c, String? s, String k) =>
      [Variable.withString(c), Variable(s), Variable.withString(k)];

  /// uses, last use and usual amount (the most frequent amount; ties: the most recently used).
  Future<({int uses, int? lastMs, double? usual})> _stats(String c, String? s, String k) async {
    final r = await database.customSelect(
        "SELECT COUNT(*) AS n, MAX(t.date_created) AS l FROM transactions t WHERE ${_match()}",
        variables: _matchVars(c, s, k)).getSingle();
    final int n = r.read<int>("n");
    if (n == 0) return (uses: 0, lastMs: null, usual: null);
    final a = await database.customSelect(
        "SELECT round(abs(t.amount), 2) AS a, COUNT(*) AS n, MAX(t.date_created) AS l FROM transactions t WHERE ${_match()} GROUP BY a ORDER BY n DESC, l DESC LIMIT 1",
        variables: _matchVars(c, s, k)).getSingle();
    return (uses: n, lastMs: r.read<int>("l") * 1000, usual: a.read<double>("a"));
  }

  Future<Map<String, dynamic>> _cats(String c, String? s) async {
    final main = await database.getCategoryInstanceOrNull(c);
    final sub = s == null ? null : await database.getCategoryInstanceOrNull(s);
    return {
      "category": {"pk": c, "name": main?.name ?? ""},
      if (s != null) "subcategory": {"pk": s, "name": sub?.name ?? ""},
    };
  }

  Future<Map<String, dynamic>> _account(String w) async {
    final wallet = await database.getWalletInstanceOrNull(w);
    return {"pk": w, "name": wallet?.name ?? "", "currency": wallet?.currency};
  }
}
