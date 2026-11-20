#!/usr/bin/env bash
# startup_release_apk.sh OUT LOG: run `bin/release --dry-run --out OUT` signed with a THROWAWAY key in
# a temporary HOME (never Brian's key, never /srv/www), writing bin/release's output to LOG.
# Exits with bin/release's status. Used by check_startup.sh.
set -euo pipefail
OUT=$1 LOG=$2
ROOT=$(git rev-parse --show-toplevel)
REAL_HOME=$HOME
H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/.config/clarity" && chmod 700 "$H/.config/clarity"
PASS=throwaway-$RANDOM$RANDOM
keytool -genkeypair -noprompt -keystore "$H/.config/clarity/release.jks" -storetype PKCS12 -alias clarity \
    -keyalg RSA -keysize 2048 -validity 2 -dname "CN=throwaway-check" -storepass "$PASS" -keypass "$PASS" >/dev/null 2>&1
printf 'CLARITY_RELEASE_STOREPASS=%s\nCLARITY_RELEASE_KEYPASS=%s\n' "$PASS" "$PASS" > "$H/.config/clarity/release.env"
chmod 600 "$H/.config/clarity/release.env"
mkdir -p "$OUT"
env -u CLARITY_RELEASE_KEYSTORE -u CLARITY_RELEASE_STOREPASS -u CLARITY_RELEASE_KEYPASS \
    HOME="$H" GRADLE_USER_HOME="${GRADLE_USER_HOME:-$REAL_HOME/.gradle}" PUB_CACHE="${PUB_CACHE:-$REAL_HOME/.pub-cache}" \
    ANDROID_USER_HOME="$REAL_HOME/.android" ANDROID_HOME="${ANDROID_HOME:-$REAL_HOME/android-sdk}" \
    PATH="$REAL_HOME/flutter/bin:$PATH" \
    bash "$ROOT/bin/release" --dry-run --out "$OUT" >"$LOG" 2>&1
