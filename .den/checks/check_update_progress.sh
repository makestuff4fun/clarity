#!/usr/bin/env bash
# Acceptance: clarity-update-progress (2026-11-24). Clarity 5.7.1: the in-app update shows its
# download (bar, percent, done / total, smoothed speed, time left), a stall, a failure with Retry
# that resumes by Range, Cancel, and the verified state, in a popup and in Settings.
# Pins: NOTES.md "clarity-update-progress".
#  1. Source: version 5.7.1+422; the checker (feed, sha256) and the Android install channel
#     unchanged since 5.7.0 (1c00192); Settings gains exactly one line (the block); server/ untouched;
#     the downloader neither prints nor logs.
#  2. Dart tests (.den/checks/dart/update_progress_test.dart, fake clock + local HTTP server, and
#     widget tests of the block).
#  3. check_self_update.sh as written.
#  4. check_favorites.sh from a patched COPY changed only where 5.7.1 changes it: its version pins
#     (5.7.0+421 -> 5.7.1+422, clarity-5.7.0.apk -> clarity-5.7.1.apk) and its "no screen changed"
#     rule, which now excludes settingsPage.dart (whose change step 1 pins to one line). That run
#     includes check_den_hook.sh, bin/release --dry-run and check_startup's APK rule.
source "$(dirname "$0")/flutter_common.sh"
BASE=1c00192   # Clarity 5.7.0+421

# 1. cheap source checks
grep -qx 'version: 5.7.1+422' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.7.1+422"
U="$B/lib/struct/update"
for f in updateDownload.dart updateProgressBlock.dart; do [ -f "$U/$f" ] || die "no $U/$f"; done
git -C "$ROOT" diff --quiet $BASE -- budget/lib/struct/update/updateChecker.dart \
    || die "updateChecker.dart changed: the feed and the verification must stay as they are"
git -C "$ROOT" diff --quiet $BASE -- budget/android server .den/checks/dart/update_checker_test.dart \
    || die "budget/android (install channel, signing) or server/ changed"
grep -q 'static const String kFeedUrl = "https://dl.hanquest.com:62280/clarity/";' "$U/updateChecker.dart" || die "feed URL changed"
grep -qE 'print\(|debugPrint|log\(' "$U/updateDownload.dart" "$U/updateProgressBlock.dart" && die "the update download prints or logs"
grep -q 'stallMs = 5000;' "$U/updateDownload.dart" || die "stall threshold is not the pinned 5 s"
grep -q 'smoothWindowMs = 3000;' "$U/updateDownload.dart" || die "speed window is not the pinned 3 s"
grep -q 'tickMs = 500;' "$U/updateDownload.dart" || die "the shown numbers do not change every 500 ms"
added=$(git -C "$ROOT" diff $BASE -- budget/lib/pages/settingsPage.dart | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' || true)
[ "$added" = "+          if (selfUpdateSupported) updateProgressInSettings()," ] \
    || die "settingsPage.dart must gain exactly the block line, got:
$added"
grep -q 'updateDownloader.snapshot.active' "$U/updates.dart" || die "a second Check for updates does not show the running download"
grep -q '^# clarity-update-progress' "$CHK/NOTES.md" || die "NOTES.md has no clarity-update-progress section"
echo "source checks: ok"

# 2. the pure parts and the block
run_dart_tests update_progress 20 "$CHK/dart/update_progress_test.dart"

# 3. the self-update as pinned
bash "$CHK/check_self_update.sh" || die "check_self_update.sh failed"

# 4. favorites (and through it den-hook, bin/release --dry-run, check_startup's APK rule)
P="$T/favorites_copy"
mkdir -p "$P"
sed -e "s|^source \"\$(dirname \"\$0\")/flutter_common.sh\"|source \"$CHK/flutter_common.sh\"|" \
    -e 's|5\.7\.0+421|5.7.1+422|g' \
    -e 's|clarity-5\.7\.0\.apk|clarity-5.7.1.apk|g' \
    -e "s|-- budget/lib/pages budget/lib/widgets |-- budget/lib/pages budget/lib/widgets ':(exclude)budget/lib/pages/settingsPage.dart' |" \
    "$CHK/check_favorites.sh" >"$P/check_favorites.sh"
grep -q "':(exclude)budget/lib/pages/settingsPage.dart'" "$P/check_favorites.sh" || die "favorites copy: the screens substitution missed"
grep -q "version: 5.7.1+422" "$P/check_favorites.sh" && grep -q "clarity-5.7.1.apk" "$P/check_favorites.sh" \
    || die "favorites copy: a version substitution missed"
grep -q "source \"$CHK/flutter_common.sh\"" "$P/check_favorites.sh" || die "favorites copy: the source substitution missed"
grep -v '^\s*#' "$P/check_favorites.sh" | grep -q '5\.7\.0+421\|clarity-5\.7\.0\.apk' && die "favorites copy still pins 5.7.0"
changed=$(diff "$CHK/check_favorites.sh" "$P/check_favorites.sh" | grep -c '^>' || true)
[ "$changed" -eq 8 ] || die "favorites copy: expected 8 changed lines, got $changed"
bash "$P/check_favorites.sh" || die "check_favorites.sh (versions moved to 5.7.1, settingsPage excluded) failed"
echo "check_update_progress: ok"
