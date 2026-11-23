#!/usr/bin/env bash
# Acceptance: clarity-favorites (2026-11-23). Clarity 5.7.0, den-app hook api 2: favorites,
# favorite_save, favorite_remove, suggestions, suggestion_dismiss. Contract: den-app docs/MONEY.md,
# "Stage 3 ... favorites, kept in Clarity (hook api 2, Clarity 5.7.0)". Pins: NOTES.md "clarity-favorites".
#  1. Source: the five methods dispatched in denHook.dart, api 2, version 5.7.0+421, the drift schema
#     and budget/lib/database unchanged since 5.6.0 (b5917ba), nothing visible added to Clarity's
#     screens (no file under lib/pages or lib/widgets changed), no new exported component, README.
#  2. Dart tests (.den/checks/dart/favorites_test.dart) for every rule, both backup directions and
#     the 20,000-row bound.
#  3. check_den_hook.sh, unchanged except for what api 2 / 5.7.0 changes by contract: its pinned
#     version (5.6.0+419 -> 5.7.0+421, clarity-5.6.0.apk -> clarity-5.7.0.apk) and its hello test
#     (api 1 -> api 2). Run from a patched COPY in a temp dir; the protected files are not touched.
#     That run includes bin/release --dry-run and check_startup's APK rule (libsqlite3.so per ABI).
source "$(dirname "$0")/flutter_common.sh"

# 1. cheap source checks
D="$B/lib/struct/denHook.dart"
F="$B/lib/struct/denFavorites.dart"
[ -f "$F" ] || die "no budget/lib/struct/denFavorites.dart"
for m in favorites favorite_save favorite_remove suggestions suggestion_dismiss; do
    grep -q "case \"$m\":" "$D" || die "denHook.dart does not dispatch $m"
done
grep -qx 'const int kDenHookApi = 2;' "$D" || die "hello does not answer api 2"
grep -qx 'version: 5.7.0+421' "$B/pubspec.yaml" || die "pubspec.yaml version is not 5.7.0+421"
grep -qx 'int schemaVersionGlobal = 48;' "$B/lib/database/tables.dart" || die "the drift schema version changed"
git -C "$ROOT" diff --quiet b5917ba -- budget/lib/database || die "budget/lib/database changed since 5.6.0: a 5.6.0 restore is no longer proven"
git -C "$ROOT" diff --quiet b5917ba -- budget/lib/pages budget/lib/widgets || die "Clarity's own screens changed (this task adds nothing visible)"
git -C "$ROOT" diff --quiet b5917ba -- budget/android/app/src/main/AndroidManifest.xml || die "the manifest changed (no new component)"
grep -q 'CREATE TABLE IF NOT EXISTS den_favorites' "$F" || die "den_favorites is not created lazily"
grep -qiE 'print\(|debugPrint|Log\.' "$F" && die "denFavorites.dart prints or logs"
grep -qiE 'DROP |DELETE FROM transactions|UPDATE transactions|ALTER ' "$F" && die "denFavorites.dart writes to Clarity's own tables"
grep -q 'GROUP BY c, s, k' "$F" || die "suggestions do not group in SQL"
grep -q 'favorite_save' "$ROOT/README.md" && grep -q 'api 2' "$ROOT/README.md" || die "README.md does not describe hook api 2"
grep -q '^# clarity-favorites' "$CHK/NOTES.md" || die "NOTES.md has no clarity-favorites section"
echo "source checks: ok"

# 2. the Dart side of api 2
run_dart_tests favorites 14 "$CHK/dart/favorites_test.dart"
grep -o 'MEASURED 20000 rows[^"]*' "$T/favorites.json" | head -1 || true

# 3. api 1 unchanged: check_den_hook.sh with only the contract's own changes
P="$T/den_hook_copy"
mkdir -p "$P/dart"
sed -e "s|^source \"\$(dirname \"\$0\")/flutter_common.sh\"|source \"$CHK/flutter_common.sh\"|" \
    -e 's|version: 5\.6\.0+419|version: 5.7.0+421|g' \
    -e 's|5\.6\.0+419|5.7.0+421|g' \
    -e 's|clarity-5\.6\.0\.apk|clarity-5.7.0.apk|g' \
    -e "s|\"\$CHK/dart/den_hook_test.dart\"|\"$P/dart/den_hook_test.dart\"|" \
    "$CHK/check_den_hook.sh" >"$P/check_den_hook.sh"
sed -e 's|test("hello answers api 1 and the version"|test("hello answers api 2 (was 1) and the version"|' \
    -e 's|"version_code": 419, "api": 1}|"version_code": 419, "api": 2}|' \
    "$CHK/dart/den_hook_test.dart" >"$P/dart/den_hook_test.dart"
# Every substitution landed, and nothing else differs.
[ "$(diff "$CHK/check_den_hook.sh" "$P/check_den_hook.sh" | grep -c '^>')" -ge 4 ] || die "check_den_hook.sh copy: a substitution missed"
grep -v '^\s*#' "$P/check_den_hook.sh" | grep -q '5\.6\.0' && die "check_den_hook.sh copy still pins 5.6.0: $(grep -n '5\.6\.0' "$P/check_den_hook.sh")"
[ "$(diff "$CHK/dart/den_hook_test.dart" "$P/dart/den_hook_test.dart" | grep -c '^>')" -eq 2 ] || die "den_hook_test.dart copy: expected exactly 2 changed lines"
grep -q '"api": 2}' "$P/dart/den_hook_test.dart" || die "den_hook_test.dart copy: hello not moved to api 2"
bash "$P/check_den_hook.sh" || die "check_den_hook.sh (api 1, versions moved to 5.7.0) failed"
echo "check_favorites: ok"
