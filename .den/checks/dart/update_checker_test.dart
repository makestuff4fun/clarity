// Acceptance: clarity/self-update. PROTECTED (.den/**); copied into budget/test/den_accept/ by
// check_self_update.sh. The pinned contract (task do:): lib/struct/update/updateChecker.dart with
//   class UpdateInfo {versionCode, versionName, sha256, url, notes}
//   class UpdateChecker({required int currentVersionCode, String feedUrl = UpdateChecker.kFeedUrl})
//     Future<UpdateInfo?> check()           GET feedUrl + "latest.json"; null unless newer, unsafe
//                                           url or offline; never throws for those
//     Future<File> download(info, File dest) GET feedUrl + info.url; sha256 verified; on mismatch
//                                           nothing is left behind and it throws
// A fake feed runs on 127.0.0.1. The feed is open: no Authorization header, ever.
import 'dart:convert';
import 'dart:io';

import 'package:budget/struct/update/updateChecker.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';

late HttpServer server;
late String feed;
Map<String, dynamic> latest = {};
List<int> apk = utf8.encode('not really an apk, but bytes to hash');
final seenAuth = <String?>[];

void main() {
  setUp(() async {
    seenAuth.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed = 'http://127.0.0.1:${server.port}/clarity/';
    server.listen((req) async {
      seenAuth.add(req.headers.value('authorization'));
      if (req.uri.path == '/clarity/latest.json') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(latest));
      } else if (req.uri.path == '/clarity/clarity-9.9.9.apk') {
        req.response.add(apk);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });
  tearDown(() async => server.close(force: true));

  Map<String, dynamic> feedFor(int code, {String? sha, String url = 'clarity-9.9.9.apk'}) => {
        'version_code': code,
        'version_name': '9.9.9',
        'sha256': sha ?? c.sha256.convert(apk).toString(),
        'url': url,
        'notes': 'standard theme',
      };

  test('the compiled-in feed is red\'s open clarity feed', () {
    expect(UpdateChecker.kFeedUrl, 'https://dl.hanquest.com:62280/clarity/');
  });

  test('not newer -> null', () async {
    latest = feedFor(500);
    expect(await UpdateChecker(currentVersionCode: 500, feedUrl: feed).check(), isNull);
    expect(await UpdateChecker(currentVersionCode: 501, feedUrl: feed).check(), isNull);
  });

  test('newer -> UpdateInfo with every field', () async {
    latest = feedFor(501);
    final i = await UpdateChecker(currentVersionCode: 500, feedUrl: feed).check();
    expect(i, isNotNull);
    expect(i!.versionCode, 501);
    expect(i.versionName, '9.9.9');
    expect(i.sha256, c.sha256.convert(apk).toString());
    expect(i.url, 'clarity-9.9.9.apk');
    expect(i.notes, 'standard theme');
    expect(seenAuth.every((a) => a == null), isTrue, reason: 'the feed is open: no Authorization header');
  });

  test('an unsafe url is refused (null)', () async {
    for (final u in ['../x.apk', 'a/b.apk', 'https://evil.example/x.apk', '']) {
      latest = feedFor(501, url: u);
      expect(await UpdateChecker(currentVersionCode: 500, feedUrl: feed).check(), isNull, reason: u);
    }
  });

  test('offline -> null, no throw', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    expect(await UpdateChecker(currentVersionCode: 1, feedUrl: 'http://127.0.0.1:$port/clarity/').check(), isNull);
  });

  test('download verifies sha256 and writes the APK', () async {
    latest = feedFor(501);
    final i = (await UpdateChecker(currentVersionCode: 500, feedUrl: feed).check())!;
    final dir = await Directory.systemTemp.createTemp('clarity-upd');
    final f = await UpdateChecker(currentVersionCode: 500, feedUrl: feed).download(i, File('${dir.path}/u.apk'));
    expect(await f.readAsBytes(), apk);
    await dir.delete(recursive: true);
  });

  test('a sha256 mismatch throws and leaves nothing behind', () async {
    latest = feedFor(501, sha: '0' * 64);
    final i = (await UpdateChecker(currentVersionCode: 500, feedUrl: feed).check())!;
    final dir = await Directory.systemTemp.createTemp('clarity-upd');
    await expectLater(
        UpdateChecker(currentVersionCode: 500, feedUrl: feed).download(i, File('${dir.path}/u.apk')),
        throwsA(anything));
    expect(dir.listSync(), isEmpty, reason: 'a bad download must leave no file (temp or final)');
    await dir.delete(recursive: true);
  });
}
