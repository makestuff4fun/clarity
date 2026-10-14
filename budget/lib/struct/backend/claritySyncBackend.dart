import 'dart:typed_data';

import 'package:budget/database/tables.dart';
import 'package:budget/struct/backend/clarityServer.dart';
import 'package:budget/struct/backend/syncBackend.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

// Pairing state lives in the app's private shared preferences, outside
// "userSettings", so it never ends up in the database or a backup.
const String _kToken = "clarityServerToken";
const String _kBaseUrl = "clarityServerUrl";
const String _kLastSha = "clarityLastUploadSha256";
const String _kLastAttempt = "clarityLastAutoBackupAttempt";
const String _kLastSettings = "clarityLastUploadSettings";

const Duration kClarityAutoBackupInterval = Duration(minutes: 15);

String? clarityToken() => sharedPreferences.getString(_kToken);

String clarityBaseUrl() =>
    sharedPreferences.getString(_kBaseUrl) ?? ClarityServer.kServerUrl;

bool get clarityPaired => (clarityToken() ?? "").isNotEmpty;

/// Stores the token issued by red for this device.
Future<void> storeClarityPairing(String token, String baseUrl) async {
  await sharedPreferences.setString(_kToken, token);
  await sharedPreferences.setString(_kBaseUrl, baseUrl);
  await sharedPreferences.remove(_kLastSha);
  await sharedPreferences.remove(_kLastAttempt);
}

String _sha256(Uint8List bytes) => crypto.sha256.convert(bytes).toString();

/// Backups on clarity-server on red. Each upload is one backup; red keeps
/// every one of them (and mirrors them to tunnel-bear), so nothing is deleted.
class ClaritySyncBackend implements SyncBackend {
  ClaritySyncBackend();

  ClarityServer get server => ClarityServer(
        baseUrl: clarityBaseUrl(),
        token: clarityToken,
      );

  SyncAccount _account() {
    final String host = Uri.parse(server.baseUrl).host;
    return SyncAccount(id: host, email: host, displayName: "Clarity on red");
  }

  @override
  SyncAccount? get currentAccount => clarityPaired ? _account() : null;

  /// "Signed in" means paired: there is a token from a clarity://provision link.
  @override
  Future<SyncAccount?> signIn({bool silent = false}) async {
    if (clarityPaired) return _account();
    if (silent) return null;
    throw "Not paired with red yet: open the clarity://provision link";
  }

  /// The token is kept: unpairing happens on red (clarity device revoke).
  @override
  Future<void> signOut() async {}

  @override
  Future<List<SyncFile>> listFiles({String? nameContains}) async {
    final List<SyncFile> files = [
      for (final ClarityBackup b in await server.list())
        SyncFile(
          id: b.id,
          name: "${b.device}-${b.sha256.substring(0, 8)}.sqlite",
          modifiedTime:
              DateTime.fromMillisecondsSinceEpoch((b.ts * 1000).round()),
          size: b.bytes,
        )
    ];
    if (nameContains == null) return files;
    return files.where((f) => f.name!.contains(nameContains)).toList();
  }

  @override
  Future<SyncFile> uploadFile({
    required String name,
    required Uint8List bytes,
    String? description,
    bool appData = true,
  }) async {
    final ClarityBackup b = await server.upload(bytes);
    await sharedPreferences.setString(_kLastSha, b.sha256);
    return SyncFile(
      id: b.id,
      name: name,
      modifiedTime: DateTime.fromMillisecondsSinceEpoch((b.ts * 1000).round()),
      size: b.bytes,
    );
  }

  @override
  Future<Uint8List> downloadFile(String fileId) => server.download(fileId);

  @override
  Future<void> deleteFile(String fileId) async =>
      throw "Deleting backups is not supported: red keeps every backup";
}

bool _autoBackupRunning = false;

/// Uploads the database to red when it changed since the last successful
/// upload. Runs on app open and resume, at most every
/// [kClarityAutoBackupInterval]; fails silently (offline, revoked, ...).
Future<void> clarityAutoBackup({bool force = false}) async {
  if (kIsWeb || _autoBackupRunning) return;
  if (syncBackend is! ClaritySyncBackend || !clarityPaired) return;
  if (appStateSettings["autoBackups"] != true) return;
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int last = sharedPreferences.getInt(_kLastAttempt) ?? 0;
  if (!force && now - last < kClarityAutoBackupInterval.inMilliseconds) return;
  _autoBackupRunning = true;
  try {
    await sharedPreferences.setInt(_kLastAttempt, now);
    // Settings travel inside the database; only rewrite them when they
    // changed, otherwise the new timestamp alone would make every check
    // look like a change.
    final String settings = sharedPreferences.getString("userSettings") ?? "";
    if (settings != "" &&
        settings != sharedPreferences.getString(_kLastSettings)) {
      await backupSettings();
    }
    final Uint8List bytes = (await getCurrentDBFileInfo()).dbFileBytes;
    final String sha = await compute(_sha256, bytes);
    if (sha == sharedPreferences.getString(_kLastSha)) return;
    await (syncBackend as ClaritySyncBackend).server.upload(bytes);
    await sharedPreferences.setString(_kLastSha, sha);
    await sharedPreferences.setString(_kLastSettings, settings);
    await updateSettings("lastBackup", DateTime.now().toString(),
        pagesNeedingRefresh: [], updateGlobalState: false);
  } catch (e) {
    print("Automatic backup to red skipped: " + e.toString());
  } finally {
    _autoBackupRunning = false;
  }
}
