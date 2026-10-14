#!/usr/bin/env bash
# Acceptance: clarity/app-sync. PROTECTED. Brian, 2026-10-14: "Add sync to tunnel-bear like all our
# app." Clarity's database lives only on the phone; this makes the phone back it up to its own
# clarity-server on red (which mirrors to tunnel-bear: server-backup), signed in with zero setup
# from an adb-fired clarity://provision link (the fleet's zero-setup rule).
#  1. the protected Dart test (.den/checks/dart/clarity_server_test.dart, 8 tests) passes;
#  2. a SyncBackend implementation backed by ClarityServer is registered with configureBackends,
#     the old "no backend" stub is not what main() installs;
#  3. AndroidManifest: exactly one activity handles VIEW clarity://provision;
#  4. flutter build apk --debug succeeds.
source "$(dirname "$0")/flutter_common.sh"
run_dart_tests clarity_server 8 "$CHK/dart/clarity_server_test.dart"
L="$B/lib"
impl=$(grep -rlE 'implements +SyncBackend' "$L/struct/backend" || true)
[ -n "$impl" ] && [ -n "$(grep -l 'ClarityServer' $impl || true)" ] \
    || die "no SyncBackend implementation in lib/struct/backend uses ClarityServer"
calls=$(grep -rn 'configureBackends(' "$L" --include=*.dart || true)
[ -n "$(grep -v 'void configureBackends' <<<"$calls" || true)" ] \
    || die "configureBackends(...) is never called: the app still runs on the stub backends"
python3 - "$B/android/app/src/main/AndroidManifest.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
A = "{http://schemas.android.com/apk/res/android}"
root = ET.parse(sys.argv[1]).getroot()
hits = []
for act in root.iter("activity"):
    for f in act.findall("intent-filter"):
        acts = {a.get(A + "name") for a in f.findall("action")}
        for d in f.findall("data"):
            if d.get(A + "scheme") == "clarity" and d.get(A + "host") == "provision" and "android.intent.action.VIEW" in acts:
                hits.append(act.get(A + "name"))
if len(hits) != 1:
    sys.exit(f"FAIL: exactly one activity must handle VIEW clarity://provision, got {hits}")
print(f"provision link handled by {hits[0]}")
PY
rm -rf "$B/build/app/outputs/flutter-apk"
(cd "$B" && flutter build apk --debug >"$T/build.log" 2>&1) || die "flutter build apk --debug failed: $(tail -20 "$T/build.log")"
echo "app-sync OK"
