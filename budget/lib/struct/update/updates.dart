// The UI side of the self-update: a silent check on start and "Check for updates" in Settings.
// The checker (updateChecker.dart) verifies the APK; Android's PackageInstaller installs it
// (MainActivity.kt, MethodChannel "com.clarity.finance/update").
import 'dart:io';

import 'package:budget/functions.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/struct/update/updateAction.dart';
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

/// The one check for the whole app, shared by Settings, About and More (updateAction.dart).
final UpdateCheckState updateCheck = UpdateCheckState(
  check: () => UpdateChecker(currentVersionCode: currentVersionCode).check(),
  downloader: updateDownloader,
);

String get installedVersionName => packageInfoGlobal?.version ?? "";

/// On start: silent unless there is a newer release (offline, no feed: nothing shown).
Future<void> checkForUpdateOnStart(BuildContext context) async {
  if (!selfUpdateSupported) return;
  final info = await updateCheck.background();
  if (info != null && context.mounted) offerUpdate(context, info);
}

/// The action in Settings, About and More: says so when there is nothing newer.
Future<void> checkForUpdatesManually(BuildContext context) async {
  if (!selfUpdateSupported) {
    openSnackbar(SnackbarMessage(title: "Updates are installed on Android only"));
    return;
  }
  // A download is going (or waits for Retry / Install): show it rather than check again
  // (UpdateCheckState.tap answers showDownload while updateDownloader.snapshot.active).
  final (outcome, info) = await updateCheck.tap(
      onStart: () => openSnackbar(SnackbarMessage(
          title: "Checking for updates…", icon: Icons.system_update_rounded)));
  if (!context.mounted) return;
  switch (outcome) {
    case UpdateTap.showDownload:
      openUpdateProgress(context);
    case UpdateTap.busy:
      break;
    case UpdateTap.upToDate:
      openSnackbar(SnackbarMessage(
        title: "No update available",
        description: "Clarity $installedVersionName is the latest, or the update feed is unreachable",
        icon: Icons.check_rounded,
      ));
    case UpdateTap.found:
      offerUpdate(context, info!);
  }
}

/// The Settings row (SettingsPageContent, under "App").
Widget updateActionInSettings(BuildContext context) => UpdateActionRow(
      supported: selfUpdateSupported,
      versionName: installedVersionName,
      state: updateCheck,
      onTap: () => checkForUpdatesManually(context),
    );

/// The About page's action, beside the version.
Widget updateActionInAbout(BuildContext context) => UpdateActionButton(
      supported: selfUpdateSupported,
      state: updateCheck,
      onTap: () => checkForUpdatesManually(context),
    );

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
