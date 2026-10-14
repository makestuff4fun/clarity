import 'package:budget/functions.dart';
import 'package:budget/main.dart';
import 'package:budget/struct/backend/clarityServer.dart';
import 'package:budget/struct/backend/claritySyncBackend.dart';
import 'package:budget/struct/backend/syncBackend.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/accountAndBackup.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/navigationFramework.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

bool isProvisionLink(Uri uri) =>
    uri.scheme == "clarity" && uri.host == "provision";

/// Handles clarity://provision: redeems the one-time code with red, stores
/// the device token, turns automatic backups on and lands on Home. Nothing
/// about the code or the token is logged.
Future<void> handleProvisionLink(Uri uri) async {
  final ProvisionLink? link = parseProvisionLink(uri);
  if (link == null) {
    openSnackbar(SnackbarMessage(
      title: "Pairing link not usable",
      description: "It has no code, or points somewhere other than red",
      icon: Icons.link_off_rounded,
    ));
    return;
  }
  await _redeem(link);
}

Future<void> _redeem(ProvisionLink link) async {
  final BuildContext? context = navigatorKey.currentContext;
  if (context != null) openLoadingPopup(context);
  try {
    final String token = await ClarityServer.redeem(
      link.code,
      baseUrl: link.baseUrl,
      appVersion: packageInfoGlobal?.version ?? "",
    );
    await storeClarityPairing(token, link.baseUrl);
    syncUser = syncBackend.currentAccount;
    await updateSettings("currentUserEmail", syncUser?.email ?? "",
        updateGlobalState: false);
    await updateSettings("hasSignedIn", true, updateGlobalState: false);
    await updateSettings("autoBackups", true,
        pagesNeedingRefresh: [], updateGlobalState: false);
    refreshUIAfterLoginChange();
    if (context != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    pageNavigationFrameworkKey.currentState?.changePage(0);
    openSnackbar(SnackbarMessage(
      title: "Backups on",
      description: "Paired with red: the database now backs up by itself",
      icon: Icons.cloud_done_rounded,
    ));
    clarityAutoBackup(force: true);
  } catch (e) {
    if (context != null) popRoute(context);
    final bool refused = e is ClarityServerException && e.status == 401;
    print("Pairing with red failed" + (refused ? ": code refused" : ""));
    openPopup(
      null,
      icon: Icons.cloud_off_rounded,
      title: refused ? "Pairing code refused" : "Could not reach red",
      description: refused
          ? "Red did not accept this pairing code. It may have expired or already been used; ask for a new link if trying again does not work."
          : "Clarity could not talk to red to finish pairing. Check the connection and try again.",
      onSubmitLabel: "Try again",
      onSubmit: () {
        popRoute(null);
        _redeem(link);
      },
      onCancelLabel: "cancel".tr(),
      onCancel: () => popRoute(null),
    );
  }
}
