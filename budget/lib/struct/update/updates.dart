// The UI side of the self-update: a silent check on start and "Check for updates" in Settings.
// The checker (updateChecker.dart) verifies the APK; Android's PackageInstaller installs it
// (MainActivity.kt, MethodChannel "com.clarity.finance/update").
import 'dart:io';

import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/update/updateChecker.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const MethodChannel updateChannel = MethodChannel("com.clarity.finance/update");

bool get selfUpdateSupported =>
    !kIsWeb && getPlatform(ignoreEmulation: true) == PlatformOS.isAndroid;

int get currentVersionCode =>
    int.tryParse(packageInfoGlobal?.buildNumber ?? "") ?? 0;

bool _checking = false;

/// On start: silent unless there is a newer release (offline, no feed: nothing shown).
Future<void> checkForUpdateOnStart(BuildContext context) async {
  if (!selfUpdateSupported || _checking) return;
  _checking = true;
  try {
    final info = await UpdateChecker(currentVersionCode: currentVersionCode).check();
    if (info != null && context.mounted) offerUpdate(context, info);
  } finally {
    _checking = false;
  }
}

/// The Settings action: says so when there is nothing newer.
Future<void> checkForUpdatesManually(BuildContext context) async {
  if (!selfUpdateSupported) {
    openSnackbar(SnackbarMessage(title: "Updates are installed on Android only"));
    return;
  }
  if (_checking) return;
  _checking = true;
  try {
    openSnackbar(SnackbarMessage(
        title: "Checking for updates…", icon: Icons.system_update_rounded));
    final info = await UpdateChecker(currentVersionCode: currentVersionCode).check();
    if (!context.mounted) return;
    if (info == null) {
      openSnackbar(SnackbarMessage(
        title: "No update available",
        description: "Clarity ${packageInfoGlobal?.version ?? ""} is the latest, or the update feed is unreachable",
        icon: Icons.check_rounded,
      ));
    } else {
      offerUpdate(context, info);
    }
  } finally {
    _checking = false;
  }
}

void offerUpdate(BuildContext context, UpdateInfo info) {
  openPopup(
    context,
    icon: Icons.system_update_rounded,
    title: "Clarity ${info.versionName} is available",
    description: info.notes.isEmpty ? null : info.notes,
    onSubmitLabel: "Update",
    onSubmit: () {
      popRoute(context);
      _downloadAndInstall(info);
    },
    onCancelLabel: "Later",
    onCancel: () => popRoute(context),
  );
}

Future<void> _downloadAndInstall(UpdateInfo info) async {
  openSnackbar(SnackbarMessage(
      title: "Downloading Clarity ${info.versionName}…",
      icon: Icons.downloading_rounded));
  try {
    final dir = Directory("${(await getTemporaryDirectory()).path}/update");
    if (await dir.exists()) await dir.delete(recursive: true);
    final apk = await UpdateChecker(currentVersionCode: currentVersionCode)
        .download(info, File("${dir.path}/clarity-update.apk"));
    final started =
        await updateChannel.invokeMethod<bool>("install", {"path": apk.path});
    if (started != true) {
      openSnackbar(SnackbarMessage(
        title: "Allow Clarity to install apps",
        description: "Then check for updates again",
        icon: Icons.security_rounded,
      ));
    }
  } catch (e) {
    openSnackbar(SnackbarMessage(
      title: "Update failed",
      description: e.toString(),
      icon: Icons.error_outline_rounded,
    ));
  }
}
