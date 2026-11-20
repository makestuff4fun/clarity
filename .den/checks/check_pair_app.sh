#!/usr/bin/env bash
# Acceptance: pair-app (2026-11-20). Clarity pairs with red by link (unchanged), by scanning a QR
# code holding a clarity://provision link, or by typing/pasting the bare code or the link.
#  1. Source: CAMERA permission in the manifest; mobile_scanner in pubspec + lock; the pair screen,
#     reachable from accountAndBackup.dart and onboarding; every route ends in redeemProvisionLink;
#     the link route still calls parseProvisionLink; nothing logs the code or token; build bumped.
#  2. Dart: .den/checks/dart/pair_app_test.dart (bare code, full link, scanned link, non-Clarity QR,
#     the form's Pair / scan / one-tap paste).
#  3. A debug APK still bundles libsqlite3.so for every ABI that ships libflutter.so.
source "$(dirname "$0")/flutter_common.sh"

# 1. cheap source checks
M="$B/android/app/src/main/AndroidManifest.xml"
grep -q 'android.permission.CAMERA' "$M" || die "AndroidManifest.xml has no CAMERA permission"
grep -qE '^  mobile_scanner: ' "$B/pubspec.yaml" || die "pubspec.yaml does not depend on mobile_scanner"
grep -qE '^  mobile_scanner:$' "$B/pubspec.lock" || die "pubspec.lock does not pin mobile_scanner"
P="$B/lib/pages/clarityPairPage.dart"
[ -f "$P" ] || die "missing $P (the Pair with red screen)"
grep -q '"Pair with red"' "$P" || die "the pair screen is not titled Pair with red"
grep -q 'MobileScanner(' "$P" || die "the pair screen has no camera scanner"
grep -q 'MobileScannerErrorCode.permissionDenied' "$P" || die "a denied camera permission is not told plainly"
grep -q 'PairSource.scanned' "$P" || die "scanned text is not read as scanned (bare text must be refused)"
[ "$(grep -c 'redeem: redeemProvisionLink' "$P")" -ge 2 ] || die "scan and type do not both end in redeemProvisionLink"
grep -q 'Clipboard.getData' "$B/lib/widgets/clarityPairForm.dart" || die "no one-tap paste"
grep -q 'openClarityPairPage' "$B/lib/widgets/accountAndBackup.dart" || die "accountAndBackup.dart does not open the pair screen"
grep -q 'openClarityPairPage' "$B/lib/pages/onBoardingPage.dart" || die "first run does not offer the pair screen"
PR="$B/lib/widgets/clarityProvision.dart"
grep -q 'parseProvisionLink(uri)' "$PR" || die "handleProvisionLink no longer parses with parseProvisionLink"
grep -q 'await redeemProvisionLink(link);' "$PR" || die "the link route does not end in redeemProvisionLink"
grep -q 'parseProvisionLink(uri)' "$B/lib/struct/clarityPairInput.dart" || die "typed/scanned links bypass parseProvisionLink"
grep -nE '(print|log|debugPrint)\(.*\b(code|token|raw|text)\b' "$P" "$B/lib/struct/clarityPairInput.dart" \
    "$B/lib/widgets/clarityPairForm.dart" && die "the pairing code or token is logged"
grep -qx 'version: 5.6.0+420' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.6.0+420"
echo "source checks: ok"

# 2. the Dart side
run_dart_tests pair_app 9 "$CHK/dart/pair_app_test.dart"

# 3. a debug APK still carries SQLite
(cd "$B" && flutter build apk --debug >"$T/apk.log" 2>&1) || die "flutter build apk --debug failed: $(tail -30 "$T/apk.log")"
APK="$B/build/app/outputs/flutter-apk/app-debug.apk"
[ -f "$APK" ] || die "no $APK"
unzip -l "$APK" >"$T/apk.list"
grep -qE ' lib/arm64-v8a/libsqlite3\.so$' "$T/apk.list" || die "no lib/arm64-v8a/libsqlite3.so in the debug APK"
for abi in $(sed -n 's|.* lib/\([^/]*\)/libflutter\.so$|\1|p' "$T/apk.list"); do
    grep -qE " lib/$abi/libsqlite3\.so$" "$T/apk.list" || die "the debug APK ships Flutter for $abi but no lib/$abi/libsqlite3.so"
done
"$BT/aapt2" dump permissions "$APK" | grep -q 'android.permission.CAMERA' || die "the built APK does not ask for CAMERA"
echo "debug APK: $(grep -c ' lib/.*/libsqlite3\.so$' "$T/apk.list") ABI(s) carry libsqlite3.so; CAMERA requested"
echo "check_pair_app: ok"
