// The fleet's in-app update, as den-app, Rebuild and the course: latest.json and the APK it
// names come from red's OPEN feed (no Authorization header, on purpose); integrity is the APK
// signature plus latest.json's sha256. Pure Dart (dart:io), so it is testable off-device.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// latest.json: {version_code, version_name, sha256, url, notes}; [url] is the APK's bare
/// name, relative to the feed.
class UpdateInfo {
  final int versionCode;
  final String versionName, sha256, url, notes;
  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.sha256,
    required this.url,
    required this.notes,
  });

  static UpdateInfo fromJson(Map<String, dynamic> j) => UpdateInfo(
        versionCode: (j["version_code"] as num).toInt(),
        versionName: j["version_name"] as String,
        sha256: (j["sha256"] as String).toLowerCase(),
        url: j["url"] as String,
        notes: (j["notes"] as String?) ?? "",
      );
}

class UpdateChecker {
  static const String kFeedUrl = "https://dl.hanquest.com:62280/clarity/";
  static const Duration _timeout = Duration(seconds: 20);

  final int currentVersionCode;
  final String feedUrl;
  UpdateChecker({required this.currentVersionCode, this.feedUrl = kFeedUrl});

  /// A bare file name in the feed: nothing that could leave it.
  static bool isSafeUrl(String url) =>
      url.isNotEmpty &&
      !url.contains("..") &&
      !url.contains("/") &&
      !url.contains("\\") &&
      !url.contains("://");

  /// The release on the feed, or null unless it is newer than this build. Null too when
  /// offline, on a bad feed, or for an unsafe url; never throws for those.
  Future<UpdateInfo?> check() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client.getUrl(Uri.parse(feedUrl + "latest.json")).timeout(_timeout);
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      final info = UpdateInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (!isSafeUrl(info.url) || info.sha256.length != 64) return null;
      return info.versionCode > currentVersionCode ? info : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the APK into a temp file beside [dest], verifies its sha256 and renames it to
  /// [dest]. On a mismatch or any failure everything written is deleted and this throws.
  Future<File> download(UpdateInfo info, File dest) async {
    if (!isSafeUrl(info.url)) throw ArgumentError("bad APK url ${info.url}");
    final tmp = File(dest.path + ".part");
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      await dest.parent.create(recursive: true);
      final req = await client.getUrl(Uri.parse(feedUrl + info.url));
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException("${info.url}: HTTP ${res.statusCode}");
      }
      final sink = tmp.openWrite();
      final digestSink = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digestSink);
      try {
        await for (final chunk in res) {
          hasher.add(chunk);
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      final got = digestSink.value.toString();
      if (got != info.sha256.toLowerCase()) {
        throw StateError("sha256 mismatch for ${info.url}: got $got, want ${info.sha256}");
      }
      return await tmp.rename(dest.path);
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      if (await dest.exists()) await dest.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
