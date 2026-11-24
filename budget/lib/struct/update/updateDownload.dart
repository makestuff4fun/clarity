// The update download with visible progress (5.7.1): bytes, total, a smoothed speed, the time
// left, a stall line, Retry that resumes with a Range request, Cancel. Pure Dart plus
// ChangeNotifier, with an injectable clock, so it is tested off-device (.den/checks/dart/
// update_progress_test.dart). The feed, the url check and the sha256 rule are UpdateChecker's;
// nothing that has not passed sha256 is ever handed to the installer.
import 'dart:async';
import 'dart:io';

import 'package:budget/struct/update/updateChecker.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// Pins (NOTES.md "clarity-update-progress").
class UpdateProgressRules {
  /// How often the shown numbers change: about twice a second, not per chunk.
  static const int tickMs = 500;

  /// Speed = bytes received over the last [smoothWindowMs] (den-app's SMOOTH_WINDOW_MS).
  static const int smoothWindowMs = 3000;

  /// No time left before this much transfer and two samples (den-app's STEADY_MIN_*).
  static const int steadyMinMs = 2000;

  /// No bytes for this long: "Waiting for the network".
  static const int stallMs = 5000;

  /// No bytes for this long: the attempt is dropped and fails (Retry resumes).
  static const int giveUpMs = 60000;

  /// Decimal megabytes, as Android's own file sizes.
  static const int mb = 1000 * 1000;
  static const int kb = 1000;
}

/// "42.1 / 116.6 MB" (one decimal, decimal MB); without a total, "42.1 MB".
String formatDoneOfTotal(int done, int? total) {
  String m(int b) => (b / UpdateProgressRules.mb).toStringAsFixed(1);
  if (total == null || total <= 0) return "${m(done)} MB";
  return "${m(done.clamp(0, total))} / ${m(total)} MB";
}

/// "1.2 MB/s" from 1 MB/s up, else whole "340 KB/s".
String formatSpeed(double bytesPerSecond) {
  final b = bytesPerSecond < 0 ? 0.0 : bytesPerSecond;
  if (b >= UpdateProgressRules.mb) {
    return "${(b / UpdateProgressRules.mb).toStringAsFixed(1)} MB/s";
  }
  return "${(b / UpdateProgressRules.kb).round()} KB/s";
}

/// "about 3 min left" (minutes rounded, from 60 s), "about 40 s left" (rounded up to 5 s).
String formatTimeLeft(int seconds) {
  if (seconds >= 60) return "about ${(seconds / 60).round()} min left";
  final s = ((seconds + 4) ~/ 5) * 5;
  return "about ${s < 5 ? 5 : s} s left";
}

/// Smoothed speed and time left from (time, bytes) samples; the clock is the caller's.
class SpeedMeter {
  final List<(int, int)> _samples = [];
  int _activeSinceMs = -1;

  void reset() {
    _samples.clear();
    _activeSinceMs = -1;
  }

  /// [bytes] is the running total of this attempt (resumed bytes included).
  void sample(int nowMs, int bytes) {
    if (_activeSinceMs < 0) _activeSinceMs = nowMs;
    _samples.add((nowMs, bytes));
    while (_samples.length > 2 &&
        nowMs - _samples[1].$1 >= UpdateProgressRules.smoothWindowMs) {
      _samples.removeAt(0);
    }
  }

  /// Bytes per second over the window, 0 with fewer than two samples.
  double speed(int nowMs) {
    if (_samples.length < 2) return 0;
    final first = _samples.first, last = _samples.last;
    final span = nowMs - first.$1;
    if (span <= 0) return 0;
    return (last.$2 - first.$2) * 1000 / span;
  }

  /// Seconds left, or null until it can be estimated.
  int? secondsLeft(int nowMs, int done, int? total) {
    if (total == null || total <= 0 || _samples.length < 2) return null;
    if (nowMs - _activeSinceMs < UpdateProgressRules.steadyMinMs) return null;
    final s = speed(nowMs);
    if (s <= 0) return null;
    return ((total - done).clamp(0, total) / s).ceil();
  }
}

enum UpdatePhase { idle, downloading, stalled, failed, verified, needsPermission }

@immutable
class UpdateSnapshot {
  final UpdatePhase phase;
  final String versionName;
  final int done;
  final int? total;
  final double speed;
  final int? secondsLeft;
  final String? message;
  const UpdateSnapshot({
    this.phase = UpdatePhase.idle,
    this.versionName = "",
    this.done = 0,
    this.total,
    this.speed = 0,
    this.secondsLeft,
    this.message,
  });
  double? get fraction =>
      total == null || total! <= 0 ? null : (done / total!).clamp(0.0, 1.0);
  int? get percent => fraction == null ? null : (fraction! * 100).floor();
  bool get active => phase != UpdatePhase.idle;
}

/// Returns true when Android's install prompt was started (false: not allowed to install).
typedef ApkInstaller = Future<bool> Function(File apk);

class _Cancelled implements Exception {}

class UpdateDownloader extends ChangeNotifier {
  final String feedUrl;
  final Directory Function() dir;
  final int Function() nowMs;
  final ApkInstaller install;
  final bool autoTick;

  UpdateDownloader({
    required this.dir,
    required this.install,
    this.feedUrl = UpdateChecker.kFeedUrl,
    int Function()? nowMs,
    this.autoTick = true,
  }) : nowMs = nowMs ?? _monotonic;

  static final Stopwatch _sw = Stopwatch()..start();
  static int _monotonic() => _sw.elapsedMilliseconds;

  UpdateSnapshot _snap = const UpdateSnapshot();
  UpdateSnapshot get snapshot => _snap;

  UpdateInfo? _info;
  HttpClient? _client;
  Timer? _timer;
  Future<void>? _run;
  bool _cancelled = false;
  int _done = 0;
  int? _total;
  int _lastByteMs = 0;
  final SpeedMeter _meter = SpeedMeter();
  File? _ready;

  /// How the last attempt started: "fresh", "resumed" or "restarted" (the server ignored Range).
  String lastStart = "";

  bool get running =>
      _snap.phase == UpdatePhase.downloading || _snap.phase == UpdatePhase.stalled;

  File _part(UpdateInfo i) => File("${dir().path}/clarity-${i.versionName}.apk.part");
  File _apk(UpdateInfo i) => File("${dir().path}/clarity-${i.versionName}.apk");

  /// Start (or carry on with) [info]. A second call while it runs does nothing.
  Future<void> start(UpdateInfo info) {
    if (running && _info?.versionName == info.versionName) return _run!;
    if (_info?.versionName != info.versionName) _ready = null;
    _info = info;
    return _run = _attempt();
  }

  /// After a failure: resume from the bytes on disk.
  Future<void> retry() => _info == null ? Future.value() : start(_info!);

  /// Stop, remove the partial file, back to nothing shown.
  Future<void> cancel() async {
    _cancelled = true;
    _client?.close(force: true);
    try {
      await _run;
    } catch (_) {}
    final info = _info;
    if (info != null) {
      for (final f in [_part(info), _apk(info)]) {
        if (await f.exists()) await f.delete();
      }
    }
    _stopTimer();
    _info = null;
    _ready = null;
    _set(const UpdateSnapshot());
  }

  /// The verified APK again (after "Allow Clarity to install apps"): checked once more first.
  Future<void> installReady() async {
    final info = _info, apk = _ready;
    if (info == null || apk == null) return;
    if (!await apk.exists() || await _sha256(apk) != info.sha256.toLowerCase()) {
      if (await apk.exists()) await apk.delete();
      _ready = null;
      _fail("The downloaded file changed and was deleted. Retry downloads it again.");
      return;
    }
    await _handOver(apk);
  }

  void _set(UpdateSnapshot s) {
    _snap = s;
    notifyListeners();
  }

  UpdateSnapshot _live({UpdatePhase? phase}) {
    final now = nowMs();
    return UpdateSnapshot(
      phase: phase ?? _snap.phase,
      versionName: _info?.versionName ?? "",
      done: _done,
      total: _total,
      speed: _meter.speed(now),
      secondsLeft: _meter.secondsLeft(now, _done, _total),
    );
  }

  /// One tick of the shown numbers; a Timer calls it every [UpdateProgressRules.tickMs]
  /// unless [autoTick] is off (tests drive it with a fake clock).
  void tick() {
    if (!running) return;
    final now = nowMs();
    final idle = now - _lastByteMs;
    if (idle >= UpdateProgressRules.giveUpMs) {
      _client?.close(force: true);
      return;
    }
    _meter.sample(now, _done);
    final stalled = idle >= UpdateProgressRules.stallMs;
    if (stalled) _meter.reset();
    _set(_live(phase: stalled ? UpdatePhase.stalled : UpdatePhase.downloading));
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _fail(String message) {
    _stopTimer();
    _set(UpdateSnapshot(
      phase: UpdatePhase.failed,
      versionName: _info?.versionName ?? "",
      done: _done,
      total: _total,
      message: message,
    ));
  }

  Future<void> _attempt() async {
    final info = _info!;
    _cancelled = false;
    _meter.reset();
    if (!UpdateChecker.isSafeUrl(info.url)) {
      _fail("The update feed named a file Clarity will not download.");
      return;
    }
    final uri = Uri.parse(feedUrl + info.url);
    final loopback = uri.host == "127.0.0.1" || uri.host == "localhost";
    if (uri.scheme != "https" && !loopback) {
      _fail("The update feed is not https.");
      return;
    }
    final d = dir();
    await d.create(recursive: true);
    // Only this version's files stay: an older version's leftovers go.
    await for (final e in d.list()) {
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (n != "clarity-${info.versionName}.apk.part" &&
          n != "clarity-${info.versionName}.apk") {
        await e.delete(recursive: true);
      }
    }
    final part = _part(info), apk = _apk(info);
    if (await apk.exists()) await apk.delete(); // never offered unverified: re-download
    int have = await part.exists() ? await part.length() : 0;
    _done = have;
    _total = null;
    _lastByteMs = nowMs();
    _set(_live(phase: UpdatePhase.downloading));
    if (autoTick) {
      _stopTimer();
      _timer = Timer.periodic(
          const Duration(milliseconds: UpdateProgressRules.tickMs), (_) => tick());
    }
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(uri);
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, "bytes=$have-");
      final res = await req.close();
      bool append = false;
      if (have > 0 && res.statusCode == 206) {
        final cr = res.headers.value(HttpHeaders.contentRangeHeader) ?? "";
        final m = RegExp(r"^bytes (\d+)-(\d+)/(\d+)$").firstMatch(cr.trim());
        if (m == null || int.parse(m.group(1)!) != have) {
          await res.drain<void>();
          throw HttpException("bad Content-Range \"$cr\"");
        }
        _total = int.parse(m.group(3)!);
        append = true;
        lastStart = "resumed";
      } else if (have > 0 && res.statusCode == 416) {
        // The bytes on disk are not a prefix of this file: start over.
        await res.drain<void>();
        await part.delete();
        client.close(force: true);
        return await _attempt();
      } else if (res.statusCode == 200) {
        lastStart = have > 0 ? "restarted" : "fresh";
        _total = res.contentLength >= 0 ? res.contentLength : null;
      } else {
        await res.drain<void>();
        throw HttpException("HTTP ${res.statusCode}");
      }
      if (!append) {
        have = 0;
        _done = 0;
      }
      final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in res) {
          if (_cancelled) throw _Cancelled();
          sink.add(chunk);
          _done += chunk.length;
          _lastByteMs = nowMs();
        }
      } finally {
        await sink.close();
      }
      if (_cancelled) throw _Cancelled();
      _stopTimer();
      // The same rules as UpdateChecker.download: the size the server gave, then sha256.
      final len = await part.length();
      if (_total != null && len != _total) {
        throw HttpException("incomplete: $len of $_total bytes");
      }
      _total ??= len;
      final got = await _sha256(part);
      if (got != info.sha256.toLowerCase()) {
        await part.delete();
        _done = 0;
        _fail("The download did not match its checksum and was deleted. "
            "Retry downloads it again.");
        return;
      }
      final ready = _ready = await part.rename(apk.path);
      _set(UpdateSnapshot(
          phase: UpdatePhase.verified,
          versionName: info.versionName,
          done: len,
          total: len));
      await _handOver(ready);
    } on _Cancelled {
      // cancel() removes the files and clears the block.
    } catch (e) {
      if (_cancelled) return;
      final what = e is SocketException || e is HttpException || e is HandshakeException
          ? "The connection dropped"
          : "The download stopped";
      _fail("$what at ${formatDoneOfTotal(_done, _total)}. "
          "Retry carries on from there.");
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> _handOver(File apk) async {
    bool started = false;
    try {
      started = await install(apk);
    } catch (_) {}
    if (!started) {
      _set(UpdateSnapshot(
        phase: UpdatePhase.needsPermission,
        versionName: _info?.versionName ?? "",
        done: _snap.done,
        total: _snap.total,
        message: "Allow Clarity to install apps, then tap Install",
      ));
    }
  }

  static Future<String> _sha256(File f) async =>
      (await crypto.sha256.bind(f.openRead()).first).toString();
}
