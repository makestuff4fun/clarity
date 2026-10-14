#!/usr/bin/env bash
# Acceptance: clarity/app-icon. PROTECTED. Brian, 2026-10-14: "fix the clarity icon ... poor masking
# and purple background but white square corners in it ... We have new icon sets, we should use
# those." The icon is hanquest-images' icons/app/clarity (fg, bg, monochrome), installed as a real
# adaptive icon; app_icon.py checks the source tree, then a freshly built debug APK.
source "$(dirname "$0")/flutter_common.sh"
RES="$B/android/app/src/main/res" MAN="$B/android/app/src/main/AndroidManifest.xml"
# 1. the source tree (fast; fails before any build while the icon is missing)
python3 "$CHK/app_icon.py" --res "$RES" --manifest "$MAN" --pubspec "$B/pubspec.yaml"
# 2. the built APK
rm -rf "$B/build/app/outputs/flutter-apk"
(cd "$B" && flutter build apk --debug >"$T/build.log" 2>&1) || die "flutter build apk --debug failed: $(tail -20 "$T/build.log")"
APK="$B/build/app/outputs/flutter-apk/app-debug.apk"
[ -f "$APK" ] || die "no debug APK at $APK"
python3 "$CHK/app_icon.py" --res "$RES" --manifest "$MAN" --pubspec "$B/pubspec.yaml" --apk "$APK" --aapt2 "$BT/aapt2"
echo "app-icon OK"
