// Acceptance: clarity/chat-button, the client half. PROTECTED (.den/**); copied into
// budget/test/den_accept/ by check_chat_button.sh. lib/struct/backend/clarityChat.dart against a
// fake clarity-server chat API (the contract of clarity/server-chat) on 127.0.0.1.
// Plain test(), never testWidgets: flutter_test's widget binding fakes every HttpClient.
import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/backend/clarityChat.dart';
import 'package:flutter_test/flutter_test.dart';

late HttpServer server;
late String base;
late Directory dir;
const tok = 'tok-chat-0123456789abcdef0123456789abcdef01';
final posts = <Map<String, dynamic>>[];
final gets = <Uri>[];
final thread = <Map<String, dynamic>>[];
int status = 200;
int nextId = 1;

Future<void> handle(HttpRequest req) async {
  final body = utf8.decode(await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b)));
  final r = req.response;
  r.headers.contentType = ContentType.json;
  if (req.headers.value('authorization') != 'Bearer $tok') {
    r.statusCode = 401;
  } else if (status != 200) {
    r.statusCode = status;
    r.write(jsonEncode({'error': {'code': 'chat_unavailable', 'message': 'down'}}));
  } else if (req.method == 'POST' && req.uri.path == '/api/v1/chat/messages') {
    final js = jsonDecode(body) as Map<String, dynamic>;
    posts.add(js);
    var m = thread.where((x) => x['client_id'] == js['client_id']).toList();
    if (m.isEmpty) {
      thread.add({'id': nextId++, 'role': 'user', 'text': js['text'], 'ts': 1.0, 'client_id': js['client_id'],
        'kind': js['kind'], 'state': 'sent', 'context': js['context']});
      m = [thread.last];
    }
    r.write(jsonEncode({'message': m.first}));
  } else if (req.method == 'GET' && req.uri.path == '/api/v1/chat/messages') {
    gets.add(req.uri);
    final after = int.tryParse(req.uri.queryParameters['after'] ?? '0') ?? 0;
    r.write(jsonEncode({'messages': thread.where((x) => (x['id'] as int) > after).toList()}));
  } else {
    r.statusCode = 404;
  }
  await r.close();
}

ClarityChat chat({String? b}) => ClarityChat(dir: dir, baseUrl: b ?? base, token: () => tok);

void main() {
  setUp(() async {
    posts.clear();
    gets.clear();
    thread.clear();
    status = 200;
    nextId = 1;
    dir = await Directory.systemTemp.createTemp('clarity-chat');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen(handle);
  });
  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  test('send queues on disk with no network', () async {
    final c = chat();
    final id = await c.send('Home total is wrong', kind: 'bug', context: {'screen': 'home'});
    expect(id, matches(RegExp(r'^[A-Za-z0-9._-]{1,64}$')));
    expect(posts, isEmpty);
    expect(await c.pendingCount(), 1);
    final ms = await c.messages();
    expect(ms.length, 1);
    expect(ms.single.id, -1);
    expect(ms.single.state, 'queued');
    expect(ms.single.kind, 'bug');
    expect(ms.single.text, 'Home total is wrong');
  });

  test('flush posts oldest first with client_id, kind and context, then dequeues', () async {
    final c = chat();
    final a = await c.send('first', kind: 'bug', context: {'screen': 'home'});
    final b = await c.send('second', kind: 'change');
    expect(await c.flush(), 2);
    expect(posts.map((p) => p['client_id']).toList(), [a, b]);
    expect(posts.map((p) => p['kind']).toList(), ['bug', 'change']);
    expect(posts.first['context'], {'screen': 'home'});
    expect(await c.pendingCount(), 0);
  });

  test('a failed flush keeps the queue, never throws, and resends the SAME client_id', () async {
    final c = chat();
    final a = await c.send('later', kind: 'change');
    status = 503;
    expect(await c.flush(), 0);
    expect(await c.pendingCount(), 1);
    status = 200;
    expect(await c.flush(), 1);
    expect(posts.single['client_id'], a);
    expect(await c.pendingCount(), 0);
  });

  test('offline: flush and fetch return 0 / [] and keep everything', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    final c = chat(b: 'http://127.0.0.1:$port');
    await c.send('offline note');
    expect(await c.flush(), 0);
    expect(await c.fetch(), isEmpty);
    expect(await c.pendingCount(), 1);
  });

  test('fetch caches the thread and asks only for newer messages', () async {
    final c = chat();
    await c.send('q', kind: 'chat');
    await c.flush();
    thread.add({'id': nextId++, 'role': 'agent', 'text': 'Queued clarity/x.', 'ts': 2.0, 'client_id': null,
      'kind': 'chat', 'state': null, 'context': null});
    final got = await c.fetch();
    expect(got.map((m) => m.role).toList(), ['user', 'agent']);
    expect(await c.fetch(), isEmpty);
    expect(gets.last.queryParameters['after'], '2');
    final ms = await c.messages();
    expect(ms.map((m) => m.text).toList(), ['q', 'Queued clarity/x.']);
  });

  test('the queue and the cache survive a restart', () async {
    final c = chat();
    await c.send('kept', kind: 'bug');
    final again = chat();
    expect(await again.pendingCount(), 1);
    expect((await again.messages()).single.text, 'kept');
  });
}
