// Acceptance: clarity-update-progress (Clarity 5.7.1). The update download's progress, speed,
// time left, stall, Retry with resume, a server without Range, sha256 on a resumed file, Cancel,
// and the block that shows them. A fake clock and a local test HTTP server; no wall-clock time.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:budget/struct/update/updateChecker.dart';
import 'package:budget/struct/update/updateDownload.dart';
import 'package:budget/struct/update/updateProgressBlock.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const int kSize = 300000;

class FakeFeed {
  late HttpServer server;
  final Uint8List blob;
  bool ranges = true;
  int? dropAfter; // the next request sends this many bytes of its body, then the socket dies
  int? pauseAfter; // the next request sends this many bytes, then waits for [gate]
  Completer<void>? gate;
  List<(int, Completer<void>)> pauses = []; // more stops in the next body, in order
  final List<String?> rangeHeaders = [];
  FakeFeed(this.blob);

  String get url => "http://127.0.0.1:${server.port}/";

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
  }

  Future<void> _serve(HttpRequest req) async {
    final range = req.headers.value(HttpHeaders.rangeHeader);
    rangeHeaders.add(range);
    int from = 0;
    final res = req.response;
    final m = range == null ? null : RegExp(r"^bytes=(\d+)-$").firstMatch(range);
    if (ranges && m != null) {
      from = int.parse(m.group(1)!);
      res.statusCode = 206;
      res.headers.set(HttpHeaders.contentRangeHeader, "bytes $from-${blob.length - 1}/${blob.length}");
    }
    res.contentLength = blob.length - from;
    final body = blob.sublist(from);
    final drop = dropAfter, pause = pauseAfter;
    dropAfter = null;
    pauseAfter = null;
    if (drop != null) {
      final sock = await res.detachSocket();
      sock.add(body.sublist(0, drop));
      await sock.flush();
      sock.destroy();
      return;
    }
    final stops = [if (pause != null) (pause, gate!), ...pauses];
    pauses = [];
    try {
      var at = 0;
      for (final (n, g) in stops) {
        res.add(body.sublist(at, n));
        await res.flush();
        await g.future;
        at = n;
      }
      res.add(body.sublist(at));
      await res.close();
    } catch (_) {
      // the client went away (Cancel, give-up): nothing to do
    }
  }
}

Future<void> until(bool Function() cond, [String what = "condition"]) async {
  for (var i = 0; i < 1000; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TestFailure("timed out waiting for $what");
}

void main() {
  late Uint8List blob;
  late String sha;
  late FakeFeed feed;
  late Directory dir;
  late int now;
  late List<File> installed;
  late UpdateDownloader dl;
  late List<UpdateSnapshot> events;

  UpdateInfo info([String? sha256]) => UpdateInfo(
      versionCode: 422, versionName: "5.7.1", sha256: sha256 ?? sha, url: "clarity-5.7.1.apk", notes: "");
  File part() => File("${dir.path}/clarity-5.7.1.apk.part");
  File apk() => File("${dir.path}/clarity-5.7.1.apk");

  setUp(() async {
    HttpOverrides.global = null; // the widget binding fakes every HttpClient with 400s
    final r = Random(7);
    blob = Uint8List.fromList(List.generate(kSize, (_) => r.nextInt(256)));
    sha = crypto.sha256.convert(blob).toString();
    feed = FakeFeed(blob);
    await feed.start();
    dir = await Directory.systemTemp.createTemp("clarity-update-test");
    now = 0;
    installed = [];
    dl = UpdateDownloader(
      dir: () => dir,
      feedUrl: feed.url,
      nowMs: () => now,
      autoTick: false,
      install: (f) async {
        installed.add(f);
        return true;
      },
    );
    events = [];
    dl.addListener(() => events.add(dl.snapshot));
  });

  tearDown(() async {
    await feed.server.close(force: true);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group("formatting", () {
    test("sizes, speeds and time left", () {
      expect(formatDoneOfTotal(42100000, 116600000), "42.1 / 116.6 MB");
      expect(formatDoneOfTotal(0, null), "0.0 MB");
      expect(formatSpeed(1234567), "1.2 MB/s");
      expect(formatSpeed(340400), "340 KB/s");
      expect(formatTimeLeft(70), "about 1 min left");
      expect(formatTimeLeft(150), "about 3 min left");
      expect(formatTimeLeft(41), "about 45 s left");
      expect(formatTimeLeft(1), "about 5 s left");
    });
  });

  group("SpeedMeter (fake clock)", () {
    test("smoothed speed over a 3 s window: one idle tick does not drop it to 0", () {
      final m = SpeedMeter();
      for (var t = 0; t <= 3000; t += 500) {
        m.sample(t, t * 200); // 200 kB/s
      }
      expect(m.speed(3000), closeTo(200000, 1));
      m.sample(3500, 600000); // nothing new for half a second
      final s = m.speed(3500);
      expect(s, greaterThan(150000));
      expect(s, lessThan(200000));
    });

    test("time left: nothing before 2 s and two samples, then remaining / speed", () {
      final m = SpeedMeter();
      m.sample(0, 0);
      expect(m.secondsLeft(0, 0, 1000000), isNull);
      m.sample(1000, 200000);
      expect(m.secondsLeft(1000, 200000, 1000000), isNull);
      m.sample(2000, 400000);
      expect(m.secondsLeft(2000, 400000, 1000000), 3);
      expect(m.secondsLeft(2000, 400000, null), isNull);
    });
  });

  group("UpdateDownloader (local HTTP server)", () {
    test("progress events carry the right bytes and total, then verified and installed", () async {
      feed.pauseAfter = 100000;
      feed.gate = Completer();
      final run = dl.start(info());
      await until(() => dl.snapshot.done == 0 && feed.rangeHeaders.isNotEmpty, "request");
      // the internal count moves per chunk; the shown one only on a tick
      for (var t = 0; t < 10 && dl.snapshot.done < 100000; t++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        now += 500;
        dl.tick();
      }
      expect(dl.snapshot.phase, UpdatePhase.downloading);
      expect(dl.snapshot.done, 100000);
      expect(dl.snapshot.total, kSize);
      expect(dl.snapshot.percent, 33);
      feed.gate!.complete();
      await run;
      expect(dl.snapshot.phase, UpdatePhase.verified);
      expect(dl.snapshot.done, kSize);
      expect(installed.single.path, apk().path);
      expect(crypto.sha256.convert(await apk().readAsBytes()).toString(), sha);
      expect(await part().exists(), isFalse);
      expect(feed.rangeHeaders, [null]);
      expect(dl.lastStart, "fresh");
      expect(events.where((e) => e.phase == UpdatePhase.downloading).map((e) => e.total).toSet(),
          containsAll(<int?>[kSize]));
    });

    test("a stall shows 'waiting' after 5 s with the bytes kept, and carries on", () async {
      feed.pauseAfter = 100000;
      feed.gate = Completer();
      final run = dl.start(info());
      now = 1000;
      await until(() {
        dl.tick();
        return dl.snapshot.done == 100000;
      }, "first bytes");
      final last = now;
      now = last + 4999;
      dl.tick();
      expect(dl.snapshot.phase, UpdatePhase.downloading);
      now = last + 5000;
      dl.tick();
      expect(dl.snapshot.phase, UpdatePhase.stalled);
      expect(dl.snapshot.done, 100000);
      feed.gate!.complete();
      await run;
      expect(dl.snapshot.phase, UpdatePhase.verified);
      expect(installed, hasLength(1));
    });

    test("a stall that recovers goes back to downloading before the end", () async {
      final m = UpdateDownloader(
          dir: () => dir, feedUrl: feed.url, nowMs: () => now, autoTick: false,
          install: (f) async => true);
      final g1 = Completer<void>(), g2 = Completer<void>();
      feed.pauses = [(50000, g1), (150000, g2)];
      final run = m.start(info());
      await until(() { m.tick(); return m.snapshot.done == 50000; }, "50000 bytes");
      now += 6000;
      m.tick();
      expect(m.snapshot.phase, UpdatePhase.stalled);
      expect(m.snapshot.done, 50000);
      g1.complete(); // bytes flow again
      await until(() { m.tick(); return m.snapshot.done == 150000; }, "150000 bytes");
      expect(m.snapshot.phase, UpdatePhase.downloading);
      expect(m.snapshot.total, kSize);
      g2.complete();
      await run;
      expect(m.snapshot.phase, UpdatePhase.verified);
    });

    test("no bytes for 60 s fails the attempt, keeping the partial file for Retry", () async {
      feed.pauseAfter = 80000;
      feed.gate = Completer();
      final run = dl.start(info());
      await until(() { dl.tick(); return dl.snapshot.done == 80000; });
      now += 60000;
      dl.tick();
      await run;
      expect(dl.snapshot.phase, UpdatePhase.failed);
      expect(await part().length(), 80000);
      feed.gate!.complete();
    });

    test("a failure, then Retry resumes with a Range request and passes sha256", () async {
      feed.dropAfter = 120000;
      await dl.start(info());
      expect(dl.snapshot.phase, UpdatePhase.failed);
      expect(dl.snapshot.message, contains("Retry"));
      expect(dl.snapshot.done, 120000);
      expect(await part().length(), 120000);
      expect(installed, isEmpty);
      await dl.retry();
      expect(feed.rangeHeaders, [null, "bytes=120000-"]);
      expect(dl.lastStart, "resumed");
      expect(dl.snapshot.phase, UpdatePhase.verified);
      expect(crypto.sha256.convert(await apk().readAsBytes()).toString(), sha);
      expect(installed.single.path, apk().path);
    });

    test("a server without Range: Retry starts over cleanly", () async {
      feed.ranges = false;
      feed.dropAfter = 120000;
      await dl.start(info());
      expect(dl.snapshot.phase, UpdatePhase.failed);
      await dl.retry();
      expect(feed.rangeHeaders, [null, "bytes=120000-"]);
      expect(dl.lastStart, "restarted");
      expect(dl.snapshot.phase, UpdatePhase.verified);
      expect(await apk().length(), kSize);
      expect(crypto.sha256.convert(await apk().readAsBytes()).toString(), sha);
    });

    test("a corrupted partial file, resumed, is refused, deleted and never installed", () async {
      await dir.create(recursive: true);
      final junk = Uint8List.fromList(blob.sublist(0, 120000));
      junk[500] ^= 0xff;
      await part().writeAsBytes(junk);
      await dl.start(info());
      expect(feed.rangeHeaders, ["bytes=120000-"]);
      expect(dl.snapshot.phase, UpdatePhase.failed);
      expect(dl.snapshot.message, contains("checksum"));
      expect(await part().exists(), isFalse);
      expect(await apk().exists(), isFalse);
      expect(installed, isEmpty);
      // Retry then downloads it all again, and that one passes
      await dl.retry();
      expect(feed.rangeHeaders.last, isNull);
      expect(dl.snapshot.phase, UpdatePhase.verified);
      expect(installed, hasLength(1));
    });

    test("a wrong sha256 in the feed: nothing is installed and nothing stays on disk", () async {
      await dl.start(info("0" * 64));
      expect(dl.snapshot.phase, UpdatePhase.failed);
      expect(await part().exists(), isFalse);
      expect(await apk().exists(), isFalse);
      expect(installed, isEmpty);
    });

    test("Cancel stops the download and removes the partial file", () async {
      feed.pauseAfter = 100000;
      feed.gate = Completer();
      final run = dl.start(info());
      await until(() { dl.tick(); return dl.snapshot.done == 100000; });
      expect(await part().exists(), isTrue);
      await dl.cancel();
      await run;
      expect(dl.snapshot.phase, UpdatePhase.idle);
      expect(dl.snapshot.active, isFalse);
      expect(await part().exists(), isFalse);
      expect(await apk().exists(), isFalse);
      expect(installed, isEmpty);
      feed.gate!.complete();
    });

    test("not allowed to install: the verified file waits behind Install, re-checked", () async {
      var allowed = false;
      final m = UpdateDownloader(
          dir: () => dir, feedUrl: feed.url, nowMs: () => now, autoTick: false,
          install: (f) async {
            installed.add(f);
            return allowed;
          });
      await m.start(info());
      expect(m.snapshot.phase, UpdatePhase.needsPermission);
      expect(await apk().exists(), isTrue);
      allowed = true;
      await m.installReady();
      expect(installed, hasLength(2));
      expect(feed.rangeHeaders, hasLength(1)); // not downloaded again
      // a file changed on disk after verification is never handed over
      final m2 = UpdateDownloader(
          dir: () => dir, feedUrl: feed.url, nowMs: () => now, autoTick: false,
          install: (f) async => false);
      await m2.start(info());
      await apk().writeAsBytes([1, 2, 3]);
      final before = installed.length;
      await m2.installReady();
      expect(m2.snapshot.phase, UpdatePhase.failed);
      expect(await apk().exists(), isFalse);
      expect(installed.length, before);
    });

    test("http to anything but this machine is refused", () async {
      final m = UpdateDownloader(
          dir: () => dir, feedUrl: "http://dl.example.com/", nowMs: () => now,
          autoTick: false, install: (f) async => true);
      await m.start(info());
      expect(m.snapshot.phase, UpdatePhase.failed);
      expect(m.snapshot.message, contains("https"));
    });
  });

  group("the block", () {
    Future<void> pump(WidgetTester t, UpdateSnapshot s,
        {VoidCallback? retry, VoidCallback? install, VoidCallback? cancel}) =>
        t.pumpWidget(MaterialApp(
            home: Scaffold(
                body: UpdateProgressView(
                    s: s, onRetry: retry, onInstall: install, onCancel: cancel))));

    testWidgets("downloading: bar, percent, size, speed, time left", (t) async {
      var cancelled = 0;
      await pump(
          t,
          const UpdateSnapshot(
              phase: UpdatePhase.downloading,
              versionName: "5.7.1",
              done: 42100000,
              total: 116600000,
              speed: 1200000,
              secondsLeft: 62),
          cancel: () => cancelled++);
      final bar = t.widget<LinearProgressIndicator>(find.byKey(const Key("update-bar")));
      expect(bar.value, closeTo(42.1 / 116.6, 0.001));
      expect(find.text("36%"), findsOneWidget);
      expect(find.text("42.1 / 116.6 MB"), findsOneWidget);
      expect(find.text("1.2 MB/s"), findsOneWidget);
      expect(find.text("about 1 min left"), findsOneWidget);
      expect(find.text("Downloading Clarity 5.7.1"), findsOneWidget);
      await t.tap(find.text("Cancel"));
      expect(cancelled, 1);
    });

    testWidgets("no time left before it can be estimated", (t) async {
      await pump(t, const UpdateSnapshot(
          phase: UpdatePhase.downloading, versionName: "5.7.1", done: 100, total: 1000));
      expect(find.byKey(const Key("update-left")), findsNothing);
      expect(find.byKey(const Key("update-speed")), findsNothing);
      expect(find.text("10%"), findsOneWidget);
    });

    testWidgets("stalled: 'Waiting for the network', bytes kept", (t) async {
      await pump(t, const UpdateSnapshot(
          phase: UpdatePhase.stalled, versionName: "5.7.1", done: 42100000, total: 116600000));
      expect(find.text("Waiting for the network"), findsOneWidget);
      expect(find.text("42.1 / 116.6 MB"), findsOneWidget);
      expect(find.byKey(const Key("update-speed")), findsNothing);
    });

    testWidgets("failed: a plain line and Retry", (t) async {
      var retried = 0;
      await pump(
          t,
          const UpdateSnapshot(
              phase: UpdatePhase.failed,
              versionName: "5.7.1",
              done: 42100000,
              total: 116600000,
              message: "The connection dropped at 42.1 / 116.6 MB. Retry carries on from there."),
          retry: () => retried++);
      expect(find.text("The connection dropped at 42.1 / 116.6 MB. Retry carries on from there."),
          findsOneWidget);
      await t.tap(find.text("Retry"));
      expect(retried, 1);
    });

    testWidgets("verified, and verified waiting for permission with Install", (t) async {
      await pump(t, const UpdateSnapshot(
          phase: UpdatePhase.verified, versionName: "5.7.1", done: 10, total: 10));
      expect(find.text("Clarity 5.7.1 is downloaded and verified"), findsOneWidget);
      expect(find.byKey(const Key("update-bar")), findsNothing);
      var installs = 0;
      await pump(
          t,
          const UpdateSnapshot(
              phase: UpdatePhase.needsPermission, versionName: "5.7.1", done: 10, total: 10),
          install: () => installs++);
      expect(find.textContaining("Allow Clarity to install apps"), findsOneWidget);
      await t.tap(find.text("Install"));
      expect(installs, 1);
    });

    testWidgets("idle: nothing shown", (t) async {
      await pump(t, const UpdateSnapshot());
      expect(find.byKey(const Key("update-block")), findsNothing);
    });
  });
}
