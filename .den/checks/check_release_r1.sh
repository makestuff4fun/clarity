#!/usr/bin/env bash
# Acceptance: clarity/release-r1. PROTECTED. The round's one version bump and a release DRY RUN
# (workers never publish; the managing agent runs bin/release for real with Brian's key).
#  1. pubspec version: build number > 416 (what is on Brian's phone) and the name moved on;
#  2. bin/release --dry-run with a THROWAWAY key builds clarity-<name>.apk at that versionCode;
#  3. the APK carries the whole round: adaptive icon with a monochrome layer (app_icon.py --apk),
#     the clarity://provision link handler, the feed URL, clarity-server's URL, REQUEST_INSTALL_PACKAGES,
#     no pixel art (no file of pixel_art.sha256 inside), no den token or key file.
source "$(dirname "$0")/flutter_common.sh"
v=$(sed -n 's/^version: *//p' "$B/pubspec.yaml")
name=${v%+*} code=${v#*+}
[[ "$code" =~ ^[0-9]+$ ]] && [ "$code" -gt 416 ] || die "pubspec version $v: the build number must be > 416"
[ "$name" != "5.4.3" ] || die "pubspec version name is still 5.4.3: bump it once for this round"
REAL_HOME=$HOME
mkdir -p "$T/home/.config/clarity" "$T/out" && chmod 700 "$T/home/.config/clarity"
PASS=throwaway-$RANDOM$RANDOM
keytool -genkeypair -noprompt -keystore "$T/home/.config/clarity/release.jks" -storetype PKCS12 -alias clarity \
    -keyalg RSA -keysize 2048 -validity 2 -dname "CN=throwaway-check" -storepass "$PASS" -keypass "$PASS" >/dev/null 2>&1
printf 'CLARITY_RELEASE_STOREPASS=%s\nCLARITY_RELEASE_KEYPASS=%s\n' "$PASS" "$PASS" > "$T/home/.config/clarity/release.env"
[ -x "$ROOT/bin/release" ] || die "bin/release missing"
env -u CLARITY_RELEASE_KEYSTORE -u CLARITY_RELEASE_STOREPASS -u CLARITY_RELEASE_KEYPASS HOME="$T/home" \
    GRADLE_USER_HOME="${GRADLE_USER_HOME:-$REAL_HOME/.gradle}" PUB_CACHE="${PUB_CACHE:-$REAL_HOME/.pub-cache}" \
    ANDROID_USER_HOME="$REAL_HOME/.android" bash "$ROOT/bin/release" --dry-run --out "$T/out" >"$T/rel.log" 2>&1 \
    || die "bin/release --dry-run failed: $(tail -30 "$T/rel.log")"
APK="$T/out/clarity-$name.apk"
[ -f "$APK" ] || die "no $APK (got: $(ls "$T/out"))"
python3 "$CHK/app_icon.py" --res "$B/android/app/src/main/res" --manifest "$B/android/app/src/main/AndroidManifest.xml" \
    --pubspec "$B/pubspec.yaml" --apk "$APK" --aapt2 "$BT/aapt2"
python3 - "$APK" "$BT" "$code" "$CHK/pixel_art.sha256" <<'PY'
import hashlib, json, re, subprocess, sys, zipfile
apk, bt, code, pixel = sys.argv[1:]
def fail(m): sys.exit("FAIL: " + m)
b = subprocess.run([f"{bt}/aapt2", "dump", "badging", apk], capture_output=True, text=True).stdout
if f"versionCode='{code}'" not in b:
    fail(f"the APK is not versionCode {code}: {b.splitlines()[0]}")
if "android.permission.REQUEST_INSTALL_PACKAGES" not in b:
    fail("no REQUEST_INSTALL_PACKAGES")
m = subprocess.run([f"{bt}/aapt2", "dump", "xmltree", "--file", "AndroidManifest.xml", apk], capture_output=True, text=True).stdout
if '"clarity"' not in m or '"provision"' not in m:
    fail("the manifest has no clarity://provision handler")
z = zipfile.ZipFile(apk)
so = z.read("lib/arm64-v8a/libapp.so")
for s in ("https://dl.hanquest.com:62280/clarity/", "https://clarity.hanquest.com:62280"):
    if s.encode() not in so:
        fail(f"{s} is not compiled in")
bad = {l.split()[0] for l in open(pixel) if l.strip() and not l.startswith("#")}
hits = [n for n in z.namelist() if not n.endswith("/") and hashlib.sha256(z.read(n)).hexdigest() in bad]
if hits:
    fail(f"pixel art still packaged: {hits[:5]}")
if any(n.endswith((".jks", ".keystore", ".env", "key.properties", "den.token")) for n in z.namelist()):
    fail("a key, env or token file is packaged")
print(f"release-r1 dry run OK: versionCode {code}")
PY
echo "release-r1 OK"
