# Sourced by clarity's acceptance checks. PROTECTED (.den/**).
# Gives: ROOT, B (budget/), CHK, die, T (temp dir, removed on exit), run_dart_tests.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
B="$ROOT/budget"
CHK="$ROOT/.den/checks"
export PATH="$HOME/flutter/bin:$HOME/.local/bin:$PATH"
export ANDROID_HOME=${ANDROID_HOME:-$HOME/android-sdk}
export ANDROID_SDK_ROOT=$ANDROID_HOME
export GRADLE_OPTS=${GRADLE_OPTS:--Dorg.gradle.caching=false}
export FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}
export PUB_HOSTED_URL=${PUB_HOSTED_URL:-https://pub.flutter-io.cn}
export LD_LIBRARY_PATH="$HOME/.local/share/clarity/sqlite-shim${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset ALL_PROXY all_proxy
BT="$ANDROID_HOME/build-tools/35.0.0"
die() { echo "FAIL: $*" >&2; exit 1; }
T=$(mktemp -d)
_INSTALLED=()
_cleanup() { rm -rf "$T" "${_INSTALLED[@]}"; }
trap _cleanup EXIT
[ -f "$B/android/local.properties" ] || printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$ANDROID_HOME" "$HOME/flutter" > "$B/android/local.properties"
[ -d "$HOME/.local/share/clarity/sqlite-shim" ] || { mkdir -p "$HOME/.local/share/clarity/sqlite-shim"; ln -sf /lib/x86_64-linux-gnu/libsqlite3.so.0 "$HOME/.local/share/clarity/sqlite-shim/libsqlite3.so"; }

# run_dart_tests NAME MIN FILE...: copy the protected Dart tests into budget/test/den_accept/NAME/
# for the duration of the check, run them with `flutter test --machine` (output to a file, never a
# pipe), and require >= MIN visible tests, every one passed, none skipped, from those files only.
run_dart_tests() {
    local name=$1 min=$2; shift 2
    local dir="$B/test/den_accept/$name"
    [ -e "$dir" ] && die "budget/test/den_accept/$name exists in the tree: acceptance tests are protected and only copied in"
    mkdir -p "$dir"
    _INSTALLED+=("$B/test/den_accept")
    cp "$@" "$dir/"
    (cd "$B" && { flutter pub get --offline >/dev/null 2>&1 || flutter pub get >"$T/pub.log" 2>&1; }) \
        || die "flutter pub get failed: $(tail -5 "$T/pub.log")"
    local rc=0
    (cd "$B" && flutter test --machine "test/den_accept/$name" >"$T/$name.json" 2>"$T/$name.err") || rc=$?
    python3 - "$T/$name.json" "$name" "$min" "$rc" "$T/$name.err" <<'PY'
import json, sys
path, name, want, rc, err = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
starts, done, errors, msgs = {}, {}, {}, []
for line in open(path, errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t = e.get("type")
    if t == "testStart":
        starts[e["test"]["id"]] = e["test"]
    elif t == "testDone":
        done[e["testID"]] = e
    elif t == "error":
        errors.setdefault(e["testID"], []).append(e.get("error", "")[:400])
    elif t == "print" and "Error" in e.get("message", ""):
        msgs.append(e["message"][:300])
vis = [(starts[i], d) for i, d in done.items() if not d.get("hidden") and i in starts
       and any(f"den_accept/{name}/" in (starts[i].get(k) or "") for k in ("url", "root_url"))]
ok = [s["name"] for s, d in vis if d.get("result") == "success" and not d.get("skipped")]
bad = [(s["name"], d.get("result"), d.get("skipped"), errors.get(s["id"], [""])[0]) for s, d in vis
       if d.get("result") != "success" or d.get("skipped")]
print(f"{name}: {len(vis)} tests, {len(ok)} passed")
if bad or len(ok) < want or len(vis) == 0:
    for b in bad:
        print(f"  - {b[0]}: {b[1]}{' (skipped)' if b[2] else ''} {b[3]}")
    if not vis:
        print("  no tests ran (compile error?):", open(err, errors="replace").read()[-1500:], *msgs[-5:], sep="\n")
    sys.exit(f"FAIL: {name} needs {want} passing tests from .den/checks/dart (got {len(ok)} of {len(vis)}, flutter rc {rc})")
PY
}
