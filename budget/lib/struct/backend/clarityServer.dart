import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Client for clarity-server on red, the only server this app talks to.
///
/// Phones pair once with a one-time code (see [parseProvisionLink]) and then
/// authenticate every request with their own bearer token. The server keeps
/// every backup it receives; red mirrors them to tunnel-bear.

/// One stored database backup.
class ClarityBackup {
  final String id;
  final String sha256;
  final String device;
  final int bytes;

  /// Seconds since the epoch, as sent by the server.
  final double ts;

  const ClarityBackup({
    required this.id,
    required this.sha256,
    required this.device,
    required this.bytes,
    required this.ts,
  });

  factory ClarityBackup.fromJson(Map<String, dynamic> js) => ClarityBackup(
        id: js["id"].toString(),
        sha256: js["sha256"].toString(),
        device: (js["device"] ?? "").toString(),
        bytes: (js["bytes"] as num).toInt(),
        ts: (js["ts"] as num).toDouble(),
      );
}

/// A failed call to clarity-server. Never carries a token or pairing code.
class ClarityServerException implements Exception {
  /// HTTP status, or null when no request was made.
  final int? status;
  final String message;
  const ClarityServerException(this.message, {this.status});

  @override
  String toString() => message;
}

class ClarityServer {
  static const String kServerUrl = "https://clarity.hanquest.com:62280";
  static const Duration _timeout = Duration(seconds: 60);

  final String baseUrl;
  final String? Function() token;

  ClarityServer({this.baseUrl = kServerUrl, required this.token});

  /// Redeems a one-time pairing code and returns this device's token.
  static Future<String> redeem(
    String code, {
    String baseUrl = kServerUrl,
    String name = "clarity-phone",
    String appVersion = "",
  }) async {
    final res = await _send(
      "POST",
      Uri.parse("$baseUrl/api/v1/pair"),
      headers: {HttpHeaders.contentTypeHeader: "application/json"},
      body: utf8.encode(jsonEncode({
        "code": code,
        "name": name,
        "platform": "android",
        "app_version": appVersion,
      })),
    );
    final js = jsonDecode(utf8.decode(res));
    final t = js is Map ? js["token"] : null;
    if (t is! String || t.isEmpty) {
      throw const ClarityServerException("Pairing answered without a token");
    }
    return t;
  }

  Future<ClarityBackup> upload(Uint8List db) async {
    final res = await _authed(
      "POST",
      "/api/v1/backups",
      headers: {
        HttpHeaders.contentTypeHeader: "application/octet-stream",
        "X-Content-Sha256": crypto.sha256.convert(db).toString(),
      },
      body: db,
    );
    return ClarityBackup.fromJson(
        jsonDecode(utf8.decode(res)) as Map<String, dynamic>);
  }

  /// Every backup on the server, newest first.
  Future<List<ClarityBackup>> list() async {
    final res = await _authed("GET", "/api/v1/backups");
    final js = jsonDecode(utf8.decode(res)) as Map<String, dynamic>;
    final l = [
      for (final b in (js["backups"] as List? ?? const []))
        ClarityBackup.fromJson(b as Map<String, dynamic>)
    ];
    l.sort((a, b) => b.ts.compareTo(a.ts));
    return l;
  }

  Future<Uint8List> download(String id) =>
      _authed("GET", "/api/v1/backups/${Uri.encodeComponent(id)}");

  Future<Uint8List> _authed(String method, String path,
      {Map<String, String> headers = const {}, List<int>? body}) {
    final t = token();
    if (t == null || t.isEmpty) {
      return Future.error(const ClarityServerException(
          "Not paired with clarity-server: open a clarity://provision link"));
    }
    return _send(method, Uri.parse("$baseUrl$path"),
        headers: {...headers, HttpHeaders.authorizationHeader: "Bearer $t"},
        body: body);
  }

  static Future<Uint8List> _send(String method, Uri uri,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, uri).timeout(_timeout);
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(_timeout);
      final bb = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(_timeout)) {
        bb.add(chunk);
      }
      final bytes = bb.takeBytes();
      if (res.statusCode != 200) {
        throw ClarityServerException(
            "clarity-server: ${_errorMessage(bytes) ?? "HTTP ${res.statusCode}"}",
            status: res.statusCode);
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  static String? _errorMessage(Uint8List bytes) {
    try {
      final js = jsonDecode(utf8.decode(bytes));
      final e = js is Map ? js["error"] : null;
      if (e is Map) return "${e["message"] ?? e["code"]}";
    } catch (_) {}
    return null;
  }
}

/// A pairing request from a clarity://provision link.
class ProvisionLink {
  final String code;
  final String baseUrl;
  const ProvisionLink(this.code, this.baseUrl);
}

/// Parses clarity://provision?code=CODE[&url=URL]. Returns null without a
/// code, or when url= points anywhere but red (https on hanquest.com or a
/// subdomain) or a local test server (http on loopback / the emulator host).
ProvisionLink? parseProvisionLink(Uri u) {
  if (u.scheme != "clarity" || u.host != "provision") return null;
  final code = (u.queryParameters["code"] ?? "").trim();
  if (code.isEmpty) return null;
  final url = u.queryParameters["url"];
  if (url == null || url.isEmpty) {
    return ProvisionLink(code, ClarityServer.kServerUrl);
  }
  final s = Uri.tryParse(url);
  if (s == null || s.host.isEmpty || s.userInfo.isNotEmpty) return null;
  final host = s.host.toLowerCase();
  final ok = (s.scheme == "https" &&
          (host == "hanquest.com" || host.endsWith(".hanquest.com"))) ||
      (s.scheme == "http" &&
          const {"127.0.0.1", "localhost", "10.0.2.2"}.contains(host));
  if (!ok) return null;
  return ProvisionLink(code, "${s.scheme}://${s.authority}");
}
