#!/usr/bin/env bash
# Worktree setup for clarity den runs. PROTECTED (.den/**). Files created here are never committed.
set -euo pipefail
export PATH="$HOME/flutter/bin:$PATH"
export FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}
export PUB_HOSTED_URL=${PUB_HOSTED_URL:-https://pub.flutter-io.cn}   # the lock file names this host
unset ALL_PROXY all_proxy   # the socks5 form breaks curl/dart; http proxies work
# 1. budget/ (the Flutter app): Gradle's SDK pointers.
printf 'sdk.dir=%s\nflutter.sdk=%s\n' "${ANDROID_HOME:-$HOME/android-sdk}" "$HOME/flutter" > budget/android/local.properties
# 2. flutter test links the system SQLite and the linker wants libsqlite3.so (README "Tests").
SHIM="$HOME/.local/share/clarity/sqlite-shim"
mkdir -p "$SHIM"
[ -e "$SHIM/libsqlite3.so" ] || ln -sf /lib/x86_64-linux-gnu/libsqlite3.so.0 "$SHIM/libsqlite3.so"
# 3. packages exactly as pubspec.lock pins them: offline first (red's cache is warm), else the mirror.
#    --enforce-lockfile: a worktree must never start with a rewritten lock file.
(cd budget && { flutter pub get --offline --enforce-lockfile >/dev/null 2>&1 || flutter pub get --enforce-lockfile >/dev/null; })
git diff --quiet -- budget/pubspec.lock || { echo "setup: pub get rewrote budget/pubspec.lock" >&2; exit 1; }
# 4. server/ (clarity-server): one shared venv per requirements pin set, built once with uv.
REQ=.den/server-requirements.txt
H=$(sha256sum "$REQ" | cut -c1-12)
V="$HOME/.local/share/clarity/check-venv-$H"
if [ ! -x "$V/bin/python" ]; then
    mkdir -p "$(dirname "$V")"
    rm -rf "$V.part"
    uv venv -q -p 3.12 "$V.part"
    uv pip install -q -p "$V.part/bin/python" -r "$REQ"
    mv "$V.part" "$V"
fi
mkdir -p server
[ -e server/.venv ] || ln -s "$V" server/.venv
