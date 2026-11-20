#!/usr/bin/env bash
# Acceptance: clarity-startup (2026-11-20). Clarity 5.5.0, the first release build, froze on the
# splash for ever: pubspec.yaml's sqlite3 hook said `source: system` for every OS, so the APK had
# no libsqlite3.so, constructDb threw in main(), and captureLogs's empty zone handler swallowed it.
#  1. Source: no `source: system` can reach an Android build; the zone's error handler is not
#     empty; main() runs its init through the startup guard; bin/release refuses an APK with no
#     libsqlite3.so; version 5.5.1+418.
#  2. bin/release --dry-run (THROWAWAY key, temp HOME) builds an APK holding
#     lib/arm64-v8a/libsqlite3.so, and libsqlite3.so for every ABI that ships libflutter.so.
#  3. The startup guard's Dart tests (.den/checks/dart/startup_guard_test.dart) pass, under
#     `flutter test` linking the system SQLite as README.md's "Tests" describes.
source "$(dirname "$0")/flutter_common.sh"

# 1. cheap source checks
python3 "$CHK/startup_pubspec.py" "$B/pubspec.yaml" || die "pubspec.yaml: see above"
LOGGING="$B/lib/struct/logging.dart"
grep -q 'runZonedGuarded' "$LOGGING" || die "captureLogs no longer uses runZonedGuarded"
if tr -d ' \n\t' <"$LOGGING" | grep -qE '\((error|e|_),(stackTrace|stack|s|__)\)\{\}'; then
    die "logging.dart: the zone's error handler is empty, so a startup failure is swallowed"
fi
grep -q 'logStartupError\|onError' "$LOGGING" || die "logging.dart: the zone's error handler does not log"
MAIN="$B/lib/main.dart"
grep -q 'runStartup(' "$MAIN" || die "main.dart does not run its init through runStartup (struct/startupGuard.dart)"
grep -q 'onError: handleStartupZoneError' "$MAIN" || die "main.dart: captureLogs is not given handleStartupZoneError"
grep -q 'StartupStep("database"' "$MAIN" || die "main.dart: the database is not a startup step"
grep -q "__android_log_write" "$B/lib/struct/logcat_ffi.dart" || die "no logcat route (liblog __android_log_write)"
grep -q 'NO_SQLITE_IN_APK' "$ROOT/bin/release" || die "bin/release does not refuse an APK without libsqlite3.so"
grep -qx 'version: 5.5.1+418' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.5.1+418"
echo "source checks: ok"

# 2. the release APK carries SQLite
bash "$CHK/startup_release_apk.sh" "$T/out" "$T/rel.log" \
    || die "bin/release --dry-run failed: $(tail -30 "$T/rel.log")"
APK=$(ls "$T"/out/*.apk 2>/dev/null | head -1)
[ -f "$APK" ] || die "bin/release --dry-run wrote no APK into --out"
case "$APK" in */clarity-5.5.1.apk) ;; *) die "expected clarity-5.5.1.apk, got $APK" ;; esac
unzip -l "$APK" >"$T/apk.list"
grep -qE ' lib/arm64-v8a/libsqlite3\.so$' "$T/apk.list" || die "no lib/arm64-v8a/libsqlite3.so in $APK:
$(grep ' lib/' "$T/apk.list")"
for abi in $(sed -n 's|.* lib/\([^/]*\)/libflutter\.so$|\1|p' "$T/apk.list"); do
    grep -qE " lib/$abi/libsqlite3\.so$" "$T/apk.list" || die "$APK ships Flutter for $abi but no lib/$abi/libsqlite3.so"
done
echo "release APK: $(grep -c ' lib/.*/libsqlite3\.so$' "$T/apk.list") ABI(s) carry libsqlite3.so"

# 3. the startup guard tests
run_dart_tests startup_guard 6 "$CHK/dart/startup_guard_test.dart"
echo "check_startup: ok"
