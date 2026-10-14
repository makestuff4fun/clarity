import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:budget/struct/backend/clarityServer.dart';

/// One message in the agent thread. Queued messages (not yet accepted by
/// clarity-server) have id -1 and state "queued".
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.kind = "chat",
    this.clientId,
    this.state,
    this.ts,
  });

  final int id;
  final String role;
  final String text;
  final String kind;
  final String? clientId;
  final String? state;
  final double? ts;

  bool get queued => state == "queued";

  factory ChatMessage.fromJson(Map<String, dynamic> js) => ChatMessage(
        id: (js["id"] as num?)?.toInt() ?? -1,
        role: "${js["role"] ?? "user"}",
        text: "${js["text"] ?? ""}",
        kind: "${js["kind"] ?? "chat"}",
        clientId: js["client_id"] as String?,
        state: js["state"] as String?,
        ts: (js["ts"] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "role": role,
        "text": text,
        "kind": kind,
        "client_id": clientId,
        "state": state,
        "ts": ts,
      };
}

/// The app's side of clarity-server's chat API (/api/v1/chat/messages), which
/// bridges to den's "Clarity" subject. Messages are queued on disk first and
/// sent by [flush]; the thread is cached on disk by [fetch]. Nothing here
/// throws on network failure.
class ClarityChat {
  ClarityChat({
    required this.dir,
    this.baseUrl = ClarityServer.kServerUrl,
    required this.token,
  });

  static const Duration _timeout = Duration(seconds: 20);

  final Directory dir;
  final String baseUrl;
  final String? Function() token;

  File get _queueFile => File("${dir.path}/chat_queue.json");
  File get _threadFile => File("${dir.path}/chat_thread.json");

  // Serializes disk access so a send during a flush cannot lose either.
  Future<void> _tail = Future.value();
  Future<T> _locked<T>(Future<T> Function() f) {
    final run = _tail.then((_) => f());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<Map<String, dynamic>>> _read(File f) async {
    try {
      if (!await f.exists()) return [];
      final js = jsonDecode(await f.readAsString());
      if (js is! List) return [];
      return js.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _write(File f, List<Map<String, dynamic>> items) async {
    await dir.create(recursive: true);
    final tmp = File("${f.path}.tmp");
    await tmp.writeAsString(jsonEncode(items), flush: true);
    await tmp.rename(f.path);
  }

  static String _newClientId() {
    final r = Random.secure();
    final rand =
        List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join();
    return "c${DateTime.now().microsecondsSinceEpoch}-$rand";
  }

  /// Queues [text] on disk (no network) and returns its client_id.
  Future<String> send(String text,
      {String kind = "chat", Map<String, dynamic>? context}) {
    return _locked(() async {
      final id = _newClientId();
      final q = await _read(_queueFile);
      q.add({
        "client_id": id,
        "text": text,
        "kind": kind,
        if (context != null) "context": context,
        "ts": DateTime.now().millisecondsSinceEpoch / 1000,
      });
      await _write(_queueFile, q);
      return id;
    });
  }

  Future<int> pendingCount() =>
      _locked(() async => (await _read(_queueFile)).length);

  /// POSTs the queue oldest first. A 200 dequeues; anything else stops and
  /// keeps the rest, to be re-sent later with the same client_id.
  Future<int> flush() {
    return _locked(() async {
      var q = await _read(_queueFile);
      var sent = 0;
      while (q.isNotEmpty) {
        final m = q.first;
        final res = await _request("POST", "/api/v1/chat/messages", body: {
          "text": m["text"],
          "client_id": m["client_id"],
          "kind": m["kind"] ?? "chat",
          if (m["context"] != null) "context": m["context"],
        });
        if (res == null) break;
        q = q.sublist(1);
        await _write(_queueFile, q);
        sent++;
      }
      return sent;
    });
  }

  /// GETs messages newer than the newest cached one, caches and returns them.
  Future<List<ChatMessage>> fetch() {
    return _locked(() async {
      final cached = await _read(_threadFile);
      final after = cached.fold<int>(
          0, (a, m) => max(a, (m["id"] as num?)?.toInt() ?? 0));
      final res = await _request("GET", "/api/v1/chat/messages?after=$after");
      final list = res?["messages"];
      if (list is! List) return <ChatMessage>[];
      final fresh = list
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => ((m["id"] as num?)?.toInt() ?? 0) > after)
          .toList();
      if (fresh.isEmpty) return <ChatMessage>[];
      await _write(_threadFile, [...cached, ...fresh]);
      return fresh.map(ChatMessage.fromJson).toList();
    });
  }

  /// The cached thread, then the queued messages (id -1, state "queued").
  Future<List<ChatMessage>> messages() {
    return _locked(() async {
      final cached = (await _read(_threadFile)).map(ChatMessage.fromJson);
      final sentIds = {for (final m in cached) m.clientId};
      final queued = (await _read(_queueFile))
          .where((m) => !sentIds.contains(m["client_id"]))
          .map((m) => ChatMessage(
                id: -1,
                role: "user",
                text: "${m["text"] ?? ""}",
                kind: "${m["kind"] ?? "chat"}",
                clientId: m["client_id"] as String?,
                state: "queued",
                ts: (m["ts"] as num?)?.toDouble(),
              ));
      return [...cached, ...queued];
    });
  }

  /// Returns the decoded JSON body on 200, null on anything else.
  Future<Map<String, dynamic>?> _request(String method, String path,
      {Map<String, dynamic>? body}) async {
    final t = token();
    if (t == null || t.isEmpty) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .openUrl(method, Uri.parse("$baseUrl$path"))
          .timeout(_timeout);
      req.headers.set(HttpHeaders.authorizationHeader, "Bearer $t");
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(_timeout);
      final text = await res.transform(utf8.decoder).join().timeout(_timeout);
      if (res.statusCode != 200) return null;
      final js = jsonDecode(text);
      return js is Map ? js.cast<String, dynamic>() : <String, dynamic>{};
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
