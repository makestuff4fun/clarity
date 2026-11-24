#!/usr/bin/env bash
# Acceptance: clarity-update-place (2026-11-24). Brian, from his phone: "I don't see a way to check
# for updates". "Check for updates" now sits where a person looks for it: a row under "App" at the
# top of Settings ("Clarity 5.7.1 · Check for updates"), an action beside the version on the About
# page, and (still) the More tile; one check state and one download behind all three.
# Pins: NOTES.md "clarity-update-place".
#  1. Source: still 5.7.1+422; the feed, verification, download, block, install channel, server/
#     untouched since 5.7.1 (4b71bad); the three places are wired, each behind selfUpdateSupported.
#  2. Dart widget tests (.den/checks/dart/update_place_test.dart).
#  3. check_update_progress.sh from a patched COPY changed only where this task changes it: its
#     "settingsPage.dart gains exactly one line" rule becomes "the block line is still there", and
#     the favorites copy it makes also excludes aboutPage.dart from "no screen changed". That run
#     includes check_self_update.sh as written, check_favorites, check_den_hook and bin/release
#     --dry-run.
source "$(dirname "$0")/flutter_common.sh"
BASE=4b71bad   # Clarity 5.7.1+422, the download's progress
S="$B/lib/pages/settingsPage.dart"
A="$B/lib/pages/aboutPage.dart"
U="$B/lib/struct/update"

# 1. cheap source checks
grep -qx 'version: 5.7.1+422' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.7.1+422 (do not bump)"
git -C "$ROOT" diff --quiet $BASE -- budget/lib/struct/update/updateChecker.dart budget/lib/struct/update/updateDownload.dart \
    budget/lib/struct/update/updateProgressBlock.dart budget/android server budget/pubspec.yaml budget/pubspec.lock bin \
    || die "the feed, verification, download, block, install channel, signing, server/ or bin/ changed"
[ -f "$U/updateAction.dart" ] || die "no $U/updateAction.dart"
grep -qE 'print\(|debugPrint|log\(' "$U/updateAction.dart" && die "updateAction.dart prints or logs"
# Settings: the "App" header and the row, before the first existing header, both gated
content=$(awk '/^class SettingsPageContent /,/^}/' "$S")
first=$(grep -n 'SettingsHeader(' <<<"$content" | head -1)
grep -q 'if (selfUpdateSupported) SettingsHeader(title: "App")' <<<"$first" || die "Settings does not open with the App header: $first"
grep -q 'if (selfUpdateSupported) updateActionInSettings(context),' <<<"$content" || die "Settings has no update row"
row=$(grep -n 'updateActionInSettings(context)' <<<"$content" | cut -d: -f1)
theme=$(grep -n 'SettingsHeader(title: "theme".tr())' <<<"$content" | cut -d: -f1)
[ "$row" -lt "$theme" ] || die "the update row is not above Theme"
# About: the action beside the version, the block under the app information (both layouts)
grep -A8 'text: getVersionString(),' "$A" | head -8 | grep -q 'if (selfUpdateSupported) updateActionInAbout(context),' \
    || die "the About page has no update action beside the version"
[ "$(grep -c 'if (selfUpdateSupported) updateProgressInSettings(),' "$A")" -eq 2 ] || die "the About page does not show the download in both layouts"
# More: the tile stays, gated, and shows the same state
grep -B2 -A8 'onTap: () => checkForUpdatesManually(context),' "$S" | grep -q 'description: updateCheck.status(),' || die "the More tile does not show the shared state"
grep -q 'if (selfUpdateSupported) updateProgressInSettings(),' "$S" || die "the More page lost the download block"
grep -q 'title: "Check for updates",' "$S" || die "the More tile is gone"
# one state, one check: every place goes through checkForUpdatesManually -> updateCheck.tap
grep -q 'await updateCheck.tap(' "$U/updates.dart" || die "the manual check does not use the shared state"
grep -q 'await updateCheck.background()' "$U/updates.dart" || die "the start check does not use the shared state"
grep -q '^bool _checking' "$U/updates.dart" && die "a second checking flag is left in updates.dart"
grep -q '^# clarity-update-place' "$CHK/NOTES.md" || die "NOTES.md has no clarity-update-place section"
echo "source checks: ok"

# 2. the widgets
run_dart_tests update_place 6 "$CHK/dart/update_place_test.dart"

# 3. check_update_progress.sh (and through it check_self_update.sh) from a patched copy
P="$T/progress_copy"
mkdir -p "$P"
sed -e "s|^source \"\$(dirname \"\$0\")/flutter_common.sh\"|source \"$CHK/flutter_common.sh\"|" \
    -e 's|^\[ "\$added" = "+          if (selfUpdateSupported) updateProgressInSettings()," \] \\$|grep -qF "          if (selfUpdateSupported) updateProgressInSettings()," "$B/lib/pages/settingsPage.dart" \\|' \
    -e "s#':(exclude)budget/lib/pages/settingsPage.dart' |\"#':(exclude)budget/lib/pages/settingsPage.dart' ':(exclude)budget/lib/pages/aboutPage.dart' |\"#" \
    "$CHK/check_update_progress.sh" >"$P/check_update_progress.sh"
grep -q "source \"$CHK/flutter_common.sh\"" "$P/check_update_progress.sh" || die "progress copy: the source substitution missed"
grep -q '^grep -qF "          if (selfUpdateSupported) updateProgressInSettings()," ' "$P/check_update_progress.sh" || die "progress copy: the settingsPage substitution missed"
grep -q "':(exclude)budget/lib/pages/aboutPage.dart' |\"" "$P/check_update_progress.sh" || die "progress copy: the aboutPage substitution missed"
changed=$(diff "$CHK/check_update_progress.sh" "$P/check_update_progress.sh" | grep -c '^>' || true)
[ "$changed" -eq 3 ] || die "progress copy: expected 3 changed lines, got $changed"
bash "$P/check_update_progress.sh" || die "check_update_progress.sh (settingsPage and aboutPage now change) failed"
echo "check_update_place: ok"
