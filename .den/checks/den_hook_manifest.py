#!/usr/bin/env python3
"""den_hook_manifest.py MANIFEST: the den hook's manifest rules (used by check_den_hook.sh).
Exactly one exported provider, ours, at com.clarity.finance.den, with no permission attribute;
and no exported component beyond the ones Clarity already had before the hook."""
import sys
import xml.etree.ElementTree as ET

A = "{http://schemas.android.com/apk/res/android}"
# Exported before 5.6.0 (launcher activity, home-screen widgets, the notification listener).
BEFORE = {
    ("activity", ".MainActivity"),
    ("service", "notification.listener.service.NotificationListener"),
    ("receiver", "PlusWidgetProvider"),
    ("receiver", "TransferWidgetProvider"),
    ("receiver", "NetWorthPlusWidgetProvider"),
    ("receiver", "NetWorthWidgetProvider"),
}
HOOK = ("provider", ".den.DenHookProvider")

root = ET.parse(sys.argv[1]).getroot()
exported = {(e.tag, e.get(A + "name")) for e in root.iter() if e.get(A + "exported") == "true"}
errors = []
if HOOK not in exported:
    errors.append("DenHookProvider is not exported")
extra = exported - BEFORE - {HOOK}
if extra:
    errors.append(f"exported components the hook may not add: {sorted(extra)}")
providers = [e for e in root.iter("provider")]
hook = [p for p in providers if p.get(A + "name") == HOOK[1]]
if len(hook) != 1:
    errors.append(f"expected one DenHookProvider, found {len(hook)}")
else:
    p = hook[0]
    if p.get(A + "authorities") != "com.clarity.finance.den":
        errors.append(f"authority is {p.get(A + 'authorities')!r}, not com.clarity.finance.den")
    for attr in ("permission", "readPermission", "writePermission", "grantUriPermissions"):
        if p.get(A + attr) is not None:
            errors.append(f"DenHookProvider has android:{attr}: it would hide the hook from den-app")
pkgs = {q.get(A + "name") for q in root.iter("package")}
if "com.hanquest.den" not in pkgs:
    errors.append("<queries> does not name com.hanquest.den")
for e in errors:
    print("manifest:", e)
sys.exit(1 if errors else 0)
