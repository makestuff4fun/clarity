#!/usr/bin/env bash
# Acceptance: clarity/self-update. PROTECTED. Brian, 2026-10-14: "Add our same update mechanism to
# it." The fleet's mechanism (den-app, Rebuild, course, learn, textadv): the app updates itself from
# red's OPEN feed https://dl.hanquest.com:62280/clarity/; integrity is the APK signature plus
# latest.json's sha256. Modelled on hanquest-course's check_self_update.sh.
#  1. The protected Dart test (.den/checks/dart/update_checker_test.dart, 7 tests) passes.
#  2. The installer: REQUEST_INSTALL_PACKAGES, a PackageInstaller session in the Kotlin side
#     behind a MethodChannel, a "Check for updates" action.
#  3. bin/release: refuses without a key (prints the keytool recipe naming ~/.config/clarity/
#     release.jks, creates nothing), refuses --out under /srv/www/dl/clarity, and a dry run signed
#     with a THROWAWAY key in a temp HOME writes exactly clarity-<versionName>.apk + latest.json.
#  4. That APK: signed only by the given key (not the debug key), not debuggable,
#     com.clarity.finance at latest.json's versionCode, REQUEST_INSTALL_PACKAGES, the feed URL and
#     "Check for updates" compiled in, no key or env file packaged.
source "$(dirname "$0")/flutter_common.sh"
APP=clarity APPID=com.clarity.finance ENVP=CLARITY
RELEASE="$ROOT/bin/release"
PUB=/srv/www/dl/$APP
REAL_HOME=$HOME

# 1. the protected Dart test
run_dart_tests update_checker 7 "$CHK/dart/update_checker_test.dart"

# 2. the installer side, in source
M="$B/android/app/src/main/AndroidManifest.xml"
grep -q 'android.permission.REQUEST_INSTALL_PACKAGES' "$M" || die "AndroidManifest.xml lacks REQUEST_INSTALL_PACKAGES"
KT=$(find "$B/android/app/src/main" -name '*.kt' -o -name '*.java' | xargs cat)
grep -q 'PackageInstaller' <<<"$KT" || die "no PackageInstaller session in the Android side (copy den-app's ApkInstaller.kt)"
grep -q 'MethodChannel' <<<"$KT" || die "no MethodChannel: Dart cannot hand the verified APK to the installer"
grep -rqi 'check for updates\|check-for-updates' "$B/lib" "$B/assets/translations" 2>/dev/null || die 'no "Check for updates" action'

# 3. the release script
[ -x "$RELEASE" ] || die "bin/release missing or not executable"
git -C "$ROOT" ls-files --error-unmatch bin/release >/dev/null 2>&1 || die "bin/release is not committed"
grep -q "/srv/www/dl/$APP" "$RELEASE" && grep -q "${ENVP}_RELEASE_STOREPASS" "$RELEASE" \
    || die "bin/release must publish to /srv/www/dl/$APP and read ${ENVP}_RELEASE_STOREPASS"
snap() { { ls -laR --time-style=full-iso "$PUB" 2>/dev/null || echo absent; } | md5sum; }
before=$(snap)
mkdir -p "$T/home" "$T/out"
# flutter and gradle keep caches under HOME: point them at the real ones
envh=(env -u "${ENVP}_RELEASE_KEYSTORE" -u "${ENVP}_RELEASE_STOREPASS" -u "${ENVP}_RELEASE_KEYPASS"
      HOME="$T/home" GRADLE_USER_HOME="${GRADLE_USER_HOME:-$REAL_HOME/.gradle}" PUB_CACHE="${PUB_CACHE:-$REAL_HOME/.pub-cache}"
      ANDROID_USER_HOME="$REAL_HOME/.android")
set +e
"${envh[@]}" bash "$RELEASE" --dry-run --out "$T/out" >"$T/nokey.log" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || die "bin/release succeeded with no keystore"
grep -q 'keytool -genkeypair' "$T/nokey.log" || die "with no keystore bin/release must print the keytool recipe:
$(tail -20 "$T/nokey.log")"
grep -q "\.config/$APP/release\.jks" "$T/nokey.log" || die "the recipe must name ~/.config/$APP/release.jks"
[ ! -e "$T/home/.config/$APP/release.jks" ] || die "bin/release created a keystore: only Brian creates the release key"
[ -z "$(ls -A "$T/out")" ] || die "bin/release wrote into --out without a key"
mkdir -p "$T/home/.config/$APP" && chmod 700 "$T/home/.config/$APP"
PASS=throwaway-$RANDOM$RANDOM
keytool -genkeypair -noprompt -keystore "$T/home/.config/$APP/release.jks" -storetype PKCS12 -alias "$APP" \
    -keyalg RSA -keysize 2048 -validity 2 -dname "CN=throwaway-check" -storepass "$PASS" -keypass "$PASS" >/dev/null 2>&1
printf '%s_RELEASE_STOREPASS=%s\n%s_RELEASE_KEYPASS=%s\n' "$ENVP" "$PASS" "$ENVP" "$PASS" > "$T/home/.config/$APP/release.env"
chmod 600 "$T/home/.config/$APP/release.env"
set +e
"${envh[@]}" bash "$RELEASE" --dry-run --out "$PUB/x" >"$T/pub.log" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || die "bin/release --dry-run --out under $PUB must refuse"
"${envh[@]}" bash "$RELEASE" --dry-run --out "$T/out" >"$T/rel.log" 2>&1 || die "bin/release --dry-run failed with a valid keystore: $(tail -30 "$T/rel.log")"
[ "$(snap)" = "$before" ] || die "a dry run changed $PUB"

# 4. the signed APK
python3 - "$T/out" "$BT" "$T/home/.config/$APP/release.jks" "$PASS" "$APP" "$APPID" "$REAL_HOME" <<'PY'
import base64, hashlib, json, re, subprocess, sys, zipfile
from pathlib import Path
out, bt, ks, pw, app, appid, home = sys.argv[1:]
out = Path(out)
def fail(m): sys.exit("FAIL: " + m)
files = sorted(p.name for p in out.iterdir())
apks = [f for f in files if f.endswith(".apk")]
if len(apks) != 1 or files != sorted(apks + ["latest.json"]):
    fail(f"--out must hold exactly {app}-<versionName>.apk and latest.json, got {files}")
apk = out / apks[0]
lj = json.loads((out / "latest.json").read_text())
if set(lj) != {"version_code", "version_name", "sha256", "url", "notes"}:
    fail(f"latest.json keys {sorted(lj)} != version_code, version_name, sha256, url, notes")
if apk.name != f"{app}-{lj['version_name']}.apk" or lj["url"] != apk.name:
    fail(f"the APK must be {app}-<version_name>.apk and latest.json url its bare name: {apk.name}, {lj}")
if lj["sha256"] != hashlib.sha256(apk.read_bytes()).hexdigest():
    fail("latest.json sha256 does not match the APK")
v = subprocess.run([f"{bt}/apksigner", "verify", "--print-certs", str(apk)], capture_output=True, text=True)
if v.returncode != 0:
    fail("apksigner verify failed: " + v.stderr)
got = set(re.findall(r"certificate SHA-256 digest: ([0-9a-f]{64})", v.stdout))
def cert(ks, alias, pw):
    k = subprocess.run(["keytool", "-exportcert", "-keystore", ks, "-alias", alias, "-storepass", pw, "-rfc"],
                       capture_output=True, text=True)
    if k.returncode != 0:
        return None
    return hashlib.sha256(base64.b64decode("".join(l for l in k.stdout.splitlines() if l and "CERTIFICATE" not in l))).hexdigest()
if got != {cert(ks, app, pw)}:
    fail(f"the APK is not signed (only) with ~/.config/{app}/release.jks alias {app}: {got}")
debug = cert(f"{home}/.android/debug.keystore", "androiddebugkey", "android")
if debug and debug in got:
    fail("signed with the debug key: releases use the release key")
b = subprocess.run([f"{bt}/aapt2", "dump", "badging", str(apk)], capture_output=True, text=True).stdout
if f"package: name='{appid}'" not in b or f"versionCode='{lj['version_code']}'" not in b \
        or f"versionName='{lj['version_name']}'" not in b:
    fail(f"the APK is not {appid} at latest.json's version: {b.splitlines()[0] if b else b}")
if "application-debuggable" in b:
    fail("the release APK is debuggable")
if "uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'" not in b:
    fail("no REQUEST_INSTALL_PACKAGES: the app cannot hand the update to the package installer")
z = zipfile.ZipFile(apk)
blob = b"".join(z.read(n) for n in z.namelist()
                if re.fullmatch(r"classes\d*\.dex|resources\.arsc|lib/arm64-v8a/libapp\.so|assets/flutter_assets/.*\.json", n))
if not any(n == "lib/arm64-v8a/libapp.so" for n in z.namelist()):
    fail("no lib/arm64-v8a/libapp.so: Brian's phone is arm64")
def has(s):
    return s.encode() in blob or s.encode("utf-16-le") in blob
feed = f"https://dl.hanquest.com:62280/{app}/"
if not has(feed):
    fail(f"the feed URL {feed} is not compiled into the APK")
if not (has("Check for updates") or has("check-for-updates")):
    fail('no "Check for updates" action in the APK')
if any(n.endswith((".jks", ".keystore", ".env", "key.properties")) for n in z.namelist()):
    fail("a key or env file is packaged")
print(f"release dry run OK: {apk.name} v{lj['version_code']}, signed with the given key, latest.json matches")
PY
hits=$(git -C "$ROOT" ls-files | grep -E '\.(jks|keystore|apk)$|(^|/)release\.env$|(^|/)local\.properties$|(^|/)key\.properties$' || true)
[ -z "$hits" ] || die "tracked files that must stay untracked: $hits"
echo "self-update OK"
