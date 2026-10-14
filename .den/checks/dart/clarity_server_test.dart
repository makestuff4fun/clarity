// Acceptance: clarity/app-sync. PROTECTED (.den/**); copied into budget/test/den_accept/ by
// check_app_sync.sh. The pinned client of clarity-server (task do:), in
// lib/struct/backend/clarityServer.dart, against a fake clarity-server on 127.0.0.1.
// Plain test(), never testWidgets: flutter_test's widget binding fakes every HttpClient.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget/struct/backend/clarityServer.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';

late HttpServer server;
late String base;
final calls = <Map<String, dynamic>>[];
final stored = <String, Uint8List>{};
const goodCode = 'apple bear cedar delta eagle fable grape hazel';
const tok = 'tok-0123456789abcdef0123456789abcdef0123456789';

Future<void> handle(HttpRequest req) async {
  final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  calls.add({
    'method': req.method,
    'path': req.uri.path,
    'auth': req.headers.value('authorization'),
    'sha': req.headers.value('x-content-sha256'),
    'body': body,
  });
  final r = req.response;
  r.headers.contentType = ContentType.json;
  final authed = req.headers.value('authorization') == 'Bearer $tok';
  if (req.method == 'POST' && req.uri.path == '/api/v1/pair') {
    final js = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    if (js['code'] == goodCode) {
      r.write(jsonEncode({'token': tok, 'device': js['name'], 'scopes': 'read write'}));
    } else {
      r.statusCode = 401;
      r.write(jsonEncode({'error': {'code': 'bad_code', 'message': 'no'}}));
    }
  } else if (!authed) {
    r.statusCode = 401;
    r.write(jsonEncode({'error': {'code': 'unauthorized', 'message': 'no'}}));
  } else if (req.method == 'POST' && req.uri.path == '/api/v1/backups') {
    final h = c.sha256.convert(body).toString();
    stored[h] = Uint8List.fromList(body);
    r.write(jsonEncode({'id': 'b-$h', 'sha256': h, 'bytes': body.length, 'ts': 1760000000.5, 'device': 'find-n6'}));
  } else if (req.method == 'GET' && req.uri.path == '/api/v1/backups') {
    r.write(jsonEncode({
      'backups': [
        {'id': 'b-2', 'sha256': 'b' * 64, 'bytes': 20, 'ts': 1760000100.0, 'device': 'find-n6'},
        {'id': 'b-1', 'sha256': 'a' * 64, 'bytes': 10, 'ts': 1760000000.0, 'device': 'find-n6'},
      ]
    }));
  } else if (req.method == 'GET' && req.uri.path.startsWith('/api/v1/backups/')) {
    final id = req.uri.pathSegments.last;
    final h = id.startsWith('b-') ? id.substring(2) : '';
    if (stored.containsKey(h)) {
      r.headers.contentType = ContentType.binary;
      r.add(stored[h]!);
    } else {
      r.statusCode = 404;
      r.write(jsonEncode({'error': {'code': 'not_found', 'message': 'no'}}));
    }
  } else {
    r.statusCode = 404;
  }
  await r.close();
}

void main() {
  setUp(() async {
    calls.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen(handle);
  });
  tearDown(() async => server.close(force: true));

  test('the compiled-in server is clarity-server on red', () {
    expect(ClarityServer.kServerUrl, 'https://clarity.hanquest.com:62280');
  });

  test('provision links: code required, url restricted to hanquest.com or loopback', () {
    final a = parseProvisionLink(Uri.parse('clarity://provision?code=apple%20bear'))!;
    expect(a.code, 'apple bear');
    expect(a.baseUrl, ClarityServer.kServerUrl);
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=x&url=https://clarity.hanquest.com:62280'))!.baseUrl,
        'https://clarity.hanquest.com:62280');
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=x&url=http://127.0.0.1:8796'))!.baseUrl,
        'http://127.0.0.1:8796');
    expect(parseProvisionLink(Uri.parse('clarity://provision')), isNull);
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=')), isNull);
    expect(parseProvisionLink(Uri.parse('other://provision?code=x')), isNull);
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=x&url=https://evil.example.com')), isNull);
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=x&url=http://clarity.hanquest.com')), isNull);
    expect(parseProvisionLink(Uri.parse('clarity://provision?code=x&url=https://hanquest.com.evil.io')), isNull);
  });

  test('redeem: a good code returns the token, a bad one throws', () async {
    expect(await ClarityServer.redeem(goodCode, baseUrl: base), tok);
    final p = calls.single;
    expect(p['path'], '/api/v1/pair');
    expect((jsonDecode(utf8.decode(p['body'] as List<int>)) as Map)['code'], goodCode);
    await expectLater(ClarityServer.redeem('wrong code', baseUrl: base), throwsA(anything));
  });

  test('upload sends the raw database with its sha256 and the bearer token', () async {
    final db = Uint8List.fromList(utf8.encode('SQLite format 3\u0000 pretend database bytes'));
    final s = ClarityServer(baseUrl: base, token: () => tok);
    final b = await s.upload(db);
    final h = c.sha256.convert(db).toString();
    expect(b.sha256, h);
    expect(b.id, 'b-$h');
    expect(b.bytes, db.length);
    final call = calls.single;
    expect(call['method'], 'POST');
    expect(call['path'], '/api/v1/backups');
    expect(call['auth'], 'Bearer $tok');
    expect(call['sha'], h);
    expect(call['body'], db);
  });

  test('list parses every backup, newest first', () async {
    final l = await ClarityServer(baseUrl: base, token: () => tok).list();
    expect(l.map((b) => b.id).toList(), ['b-2', 'b-1']);
    expect(l.first.sha256, 'b' * 64);
    expect(l.first.bytes, 20);
    expect(l.first.device, 'find-n6');
    expect(l.first.ts, closeTo(1760000100.0, 0.001));
  });

  test('download returns the exact bytes', () async {
    final s = ClarityServer(baseUrl: base, token: () => tok);
    final db = Uint8List.fromList(utf8.encode('SQLite format 3\u0000 another'));
    final b = await s.upload(db);
    expect(await s.download(b.id), db);
    await expectLater(s.download('b-nope'), throwsA(anything));
  });

  test('not paired: no request is made, it throws', () async {
    final s = ClarityServer(baseUrl: base, token: () => null);
    await expectLater(s.list(), throwsA(anything));
    await expectLater(s.upload(Uint8List.fromList([1, 2, 3])), throwsA(anything));
    expect(calls, isEmpty);
  });

  test('a 401 (revoked) throws', () async {
    await expectLater(ClarityServer(baseUrl: base, token: () => 'revoked').list(), throwsA(anything));
  });
}
