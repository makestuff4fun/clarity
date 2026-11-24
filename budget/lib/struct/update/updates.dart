// The UI side of the self-update: a silent check on start and "Check for updates" in Settings.
// The checker (updateChecker.dart) verifies the APK; Android's PackageInstaller installs it
// (MainActivity.kt, MethodChannel "com.clarity.finance/update").
import 'dart:io';

import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/update/updateChecker.dart';
import 'package:budget/struct/update/updateDownload.dart';
import 'package:budget/struct/update/updateProgressBlock.dart';
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
  // A download is going (or waits for Retry / Install): show it rather than check again.
  if (updateDownloader.snapshot.active) {
    openUpdateProgress(context);
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
      _downloadAndInstall(context, info);
    },
    onCancelLabel: "Later",
    onCancel: () => popRoute(context),
  );
}

Directory? _updateDir;

/// The one download for the whole app: it lives here, not in a widget, so leaving the
/// screen, opening another page or rotating neither stops nor restarts it.
final UpdateDownloader updateDownloader = UpdateDownloader(
  dir: () => _updateDir!,
  install: (apk) async =>
      await updateChannel.invokeMethod<bool>("install", {"path": apk.path}) == true,
);

/// The block in Settings, under "Check for updates" (nothing while no download is going).
Widget updateProgressInSettings() => UpdateProgressBlock(
      downloader: updateDownloader,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 10),
    );

/// The popup with the live block; closing it leaves the download running.
void openUpdateProgress(BuildContext context) {
  openPopupCustom(
    context,
    title: "Update",
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      UpdateProgressBlock(downloader: updateDownloader),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton(onPressed: () => popRoute(context), child: const Text("Close")),
      ),
    ]),
  );
}

Future<void> _downloadAndInstall(BuildContext context, UpdateInfo info) async {
  _updateDir ??= Directory("${(await getTemporaryDirectory()).path}/update");
  final run = updateDownloader.start(info);
  if (context.mounted) openUpdateProgress(context);
  await run;
  if (updateDownloader.snapshot.phase == UpdatePhase.needsPermission) {
    openSnackbar(SnackbarMessage(
      title: "Allow Clarity to install apps",
      description: "Then tap Install under Check for updates",
      icon: Icons.security_rounded,
    ));
  }
}
