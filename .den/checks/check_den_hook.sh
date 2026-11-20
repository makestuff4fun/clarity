#!/usr/bin/env bash
# Acceptance: den-hook (2026-11-20). Clarity 5.6.0 exports the den-app hook pinned in den-app
# docs/MONEY.md "The hook, as pinned (2026-11-20)": content://com.clarity.finance.den, call() only.
#  1. Source: the provider and its authority, exported with no permission attribute and no other
#     new exported component; the pinned certificate constant; the caller check runs in call();
#     the adb-shell allowance exists in src/debug only; no schema version change (48); nothing
#     logs the request; version 5.6.0+419.
#  2. Dart: .den/checks/dart/den_hook_test.dart (every method, over Clarity's real write path).
#  3. JVM: the caller check (DenHookCallerTest) under gradle's testReleaseUnitTest.
#  4. bin/release --dry-run (THROWAWAY key): clarity-5.6.0.apk, libsqlite3.so for every ABI that
#     ships libflutter.so (check_startup's APK rule), the provider in the built manifest, and the
#     debug-only shell allowance absent from the release dex.
source "$(dirname "$0")/flutter_common.sh"
A="$B/android/app/src"
K="$A/main/kotlin/com/clarity/finance/den"

# 1. cheap source checks
python3 "$CHK/den_hook_manifest.py" "$A/main/AndroidManifest.xml" || die "AndroidManifest.xml: see above"
for f in DenHookProvider.kt DenHookEngine.kt DenHookCaller.kt; do
    [ -f "$K/$f" ] || die "missing $K/$f"
done
grep -q 'const val DEN_CERT_SHA256 = "1931299e6edfeec066087b128e0af467e702f4e48836fde8df6adbe7f35a7a07"' "$K/DenHookCaller.kt" \
    || die "DenHookCaller.kt does not pin den-app's certificate SHA-256"
grep -q 'const val DEN_PACKAGE = "com.hanquest.den"' "$K/DenHookCaller.kt" || die "DenHookCaller.kt does not pin com.hanquest.den"
grep -q 'signingCertificateHistory' "$K/DenHookProvider.kt" || die "the caller check ignores rotated certificates"
python3 -c '
import re, sys
s = open(sys.argv[1]).read()
body = s[s.index("override fun call("):]
body = body[:body.index("DenHookEngine.call(")]
sys.exit(0 if "Binder.getCallingUid()" in body and "DenHookCaller.isAllowed(" in body else 1)
' "$K/DenHookProvider.kt" || die "DenHookProvider.call does not check Binder.getCallingUid() before the work"
grep -q 'Process.SHELL_UID' "$A/debug/kotlin/com/clarity/finance/den/DenHookBuild.kt" || die "no debug-only shell allowance"
for v in release profile; do
    f="$A/$v/kotlin/com/clarity/finance/den/DenHookBuild.kt"
    grep -q 'fun extraAllowed(uid: Int): Boolean = false' "$f" || die "$f must allow nobody"
    grep -q 'SHELL' "$f" && die "$f mentions the shell"
done
grep -rq 'SHELL_UID\|uid == 2000' "$A/main" && die "src/main reaches the shell uid: the allowance belongs in src/debug only"
grep -q "release.java.srcDirs += 'src/release/kotlin'" "$B/android/app/build.gradle" || die "build.gradle does not compile src/release/kotlin"
grep -rnE 'Log\.[a-z]\(.*\b(arg|extras|json)\b' "$K" && die "the provider logs the request or answer (ids and codes only)"
grep -qx 'int schemaVersionGlobal = 48;' "$B/lib/database/tables.dart" || die "the drift schema version changed"
grep -q 'den_hook' "$B/lib/database/tables.dart" && die "tables.dart mentions the den hook: the id lives outside the schema"
D="$B/lib/struct/denHook.dart"
grep -q 'createOrUpdateTransaction(' "$D" || die "denHook.dart does not write through createOrUpdateTransaction"
grep -q 'deleteTransaction(' "$D" || die "denHook.dart does not remove through deleteTransaction"
grep -q 'getMainAndSubcategoryFromParams' "$D" || die "denHook.dart does not match names as appLinks.dart does"
grep -qiE 'customStatement|customInsert|INSERT INTO' "$D" && die "denHook.dart writes SQL by hand"
grep -q "@pragma('vm:entry-point')" "$B/lib/main.dart" && grep -q 'void denHookMain()' "$B/lib/main.dart" \
    || die "main.dart has no headless entrypoint denHookMain"
grep -q '"denHookMain"' "$K/DenHookEngine.kt" || die "DenHookEngine does not start denHookMain"
grep -q 'TIMEOUT_MS = 10_000L' "$K/DenHookEngine.kt" || die "DenHookEngine does not give up after 10 s"
grep -q 'DenHookEngine.attachUi' "$A/main/kotlin/com/clarity/finance/MainActivity.kt" || die "MainActivity does not hand its engine to the hook"
grep -qx 'version: 5.6.0+419' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.6.0+419"
grep -q 'content://com.clarity.finance.den' "$ROOT/README.md" || die "README.md does not describe the hook"
echo "source checks: ok"

# 2. the Dart side of every method
run_dart_tests den_hook 12 "$CHK/dart/den_hook_test.dart"

# 3. the caller check, on the JVM
GRADLE=$(ls -d "$HOME"/.gradle/wrapper/dists/gradle-8.14.3-bin/*/gradle-8.14.3/bin/gradle 2>/dev/null | head -1)
[ -x "$GRADLE" ] || die "no gradle 8.14.3 in ~/.gradle/wrapper/dists"
RES="$B/build/app/test-results/testReleaseUnitTest"
rm -rf "$RES"
(cd "$B/android" && "$GRADLE" --offline -q :app:testReleaseUnitTest --tests 'com.clarity.finance.den.*' >"$T/jvm.log" 2>&1) \
    || die "testReleaseUnitTest failed: $(tail -30 "$T/jvm.log")"
python3 -c '
import glob, sys, xml.etree.ElementTree as ET
n = bad = 0
for f in glob.glob(sys.argv[1] + "/TEST-*DenHookCaller*.xml"):
    r = ET.parse(f).getroot()
    n += int(r.get("tests")); bad += int(r.get("failures")) + int(r.get("errors")) + int(r.get("skipped"))
print(f"DenHookCallerTest: {n} tests, {n - bad} passed")
sys.exit(0 if n >= 6 and bad == 0 else 1)
' "$RES" || die "the caller check's JVM tests did not all pass"

# 4. the release APK
bash "$CHK/startup_release_apk.sh" "$T/out" "$T/rel.log" \
    || die "bin/release --dry-run failed: $(tail -30 "$T/rel.log")"
APK=$(ls "$T"/out/*.apk 2>/dev/null | head -1)
[ -f "$APK" ] || die "bin/release --dry-run wrote no APK into --out"
case "$APK" in */clarity-5.6.0.apk) ;; *) die "expected clarity-5.6.0.apk, got $APK" ;; esac
unzip -l "$APK" >"$T/apk.list"
grep -qE ' lib/arm64-v8a/libsqlite3\.so$' "$T/apk.list" || die "no lib/arm64-v8a/libsqlite3.so in $APK"
for abi in $(sed -n 's|.* lib/\([^/]*\)/libflutter\.so$|\1|p' "$T/apk.list"); do
    grep -qE " lib/$abi/libsqlite3\.so$" "$T/apk.list" || die "$APK ships Flutter for $abi but no lib/$abi/libsqlite3.so"
done
"$BT/aapt2" dump xmltree --file AndroidManifest.xml "$APK" >"$T/manifest.txt" || die "aapt2 could not read the APK manifest"
grep -q '"com.clarity.finance.den"' "$T/manifest.txt" || die "the built manifest has no com.clarity.finance.den provider"
mkdir -p "$T/dex" && unzip -q -o "$APK" 'classes*.dex' -d "$T/dex"
cat "$T"/dex/classes*.dex >"$T/all.dex"
grep -qa '1931299e6edfeec066087b128e0af467e702f4e48836fde8df6adbe7f35a7a07' "$T/all.dex" \
    || die "the release dex does not carry the pinned certificate (is the provider compiled in?)"
grep -qa 'den-hook-debug-shell-allowance' "$T/all.dex" && die "the debug-only adb shell allowance is in the RELEASE APK"
echo "release APK: $(grep -c ' lib/.*/libsqlite3\.so$' "$T/apk.list") ABI(s) carry libsqlite3.so; provider in; shell allowance out"
echo "check_den_hook: ok"
