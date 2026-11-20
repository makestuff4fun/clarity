"""startup_pubspec.py PUBSPEC: fail if the sqlite3 build hook could link the *system* SQLite in an
Android build (Android has no SQLite an app may load: Clarity 5.5.0 froze on the splash for this).
`source` is a string (applies to every OS) or a map from OS name / `default` to a string, as
package:sqlite3's hook (lib/src/hook/compile/description.dart, forTargetOS) reads it."""
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1]))
defines = ((doc.get("hooks") or {}).get("user_defines") or {}).get("sqlite3") or {}
src = defines.get("source")
if isinstance(src, dict):
    android = src.get("android", src.get("default"))
else:
    android = src
if android in ("system", "process", "executable"):
    sys.exit(f"FAIL: pubspec.yaml hooks.user_defines.sqlite3.source gives Android {android!r}: "
             "the APK would carry no libsqlite3.so")
print(f"pubspec: Android sqlite3 source = {android or 'sqlite3 (default prebuilt)'}")
