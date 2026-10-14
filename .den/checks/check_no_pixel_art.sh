#!/usr/bin/env bash
# Acceptance: clarity/no-pixel-art. PROTECTED. Brian, 2026-10-14: "Change the theme back to more
# standard, ditch the 8bit. I don't like it." The 24 files of the August retro reskin (5cd921f;
# hashes in pixel_art.sha256) go, replaced by standard Material art:
#  1. no file under budget/ (build output aside) has the bytes of any of the 24, under any name;
#  2. assets/landing/, assets/images/ and assets/icons/fun/ hold no raster images, and every
#     "assets/...(png|jpg|jpeg|webp|gif)" literal in lib/ names a file that exists;
#  3. each of the 11 Android drawables (widgets, widget previews, quick-action shortcuts,
#     notification icon) is no longer a PNG: if anything still references it, it is an XML
#     drawable (vector / shape / layer-list / inset / selector), never a bitmap;
#  4. flutter build apk --debug succeeds (the XML compiles, the Dart compiles).
source "$(dirname "$0")/flutter_common.sh"
python3 - "$ROOT" "$CHK/pixel_art.sha256" <<'PY'
import hashlib, re, sys, xml.etree.ElementTree as ET
from pathlib import Path
root, manifest = Path(sys.argv[1]), Path(sys.argv[2])
b = root / "budget"
bad = {}
for line in manifest.read_text().splitlines():
    if line and not line.startswith("#"):
        h, p = line.split(None, 1)
        bad[h] = p
fail = []
skip = ("build", ".dart_tool", ".gradle")
for f in b.rglob("*"):
    if f.is_file() and not any(part in skip for part in f.relative_to(b).parts) and f.stat().st_size < 4_000_000:
        h = hashlib.sha256(f.read_bytes()).hexdigest()
        if h in bad:
            fail.append(f"{f.relative_to(root)} is the pixel art {bad[h]}")
for d in ("assets/landing", "assets/images", "assets/icons/fun"):
    for f in (b / d).glob("*") if (b / d).is_dir() else []:
        if f.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp", ".gif"):
            fail.append(f"{f.relative_to(root)}: {d}/ must hold no raster art (use Material icons)")
for f in (b / "lib").rglob("*.dart"):
    for m in re.finditer(r"[\"'](assets/[^\"'$]+\.(?:png|jpe?g|webp|gif))[\"']", f.read_text(errors="replace")):
        if not (b / m.group(1)).is_file():
            fail.append(f"{f.relative_to(root)} names {m.group(1)}, which does not exist")
res = b / "android/app/src/main/res"
names = ["addtransaction", "net_worth_plus_widget", "net_worth_widget", "notification_icon_android2", "piggybank",
         "plus", "plus_button", "plus_widget", "transfer", "transfer_widget", "transfertransaction"]
refs = "\n".join(p.read_text(errors="replace") for p in [*res.rglob("*.xml"), *(b / "lib").rglob("*.dart"),
                 b / "android/app/src/main/AndroidManifest.xml", *(b / "android/app/src/main").rglob("*.kt")])
for n in names:
    for p in res.glob(f"drawable*/{n}.*"):
        if p.suffix != ".xml":
            fail.append(f"{p.relative_to(root)}: still a bitmap")
    used = re.search(rf"@drawable/{n}\b|[\"']{n}[\"']", refs)
    x = res / "drawable" / f"{n}.xml"
    if used:
        if not x.is_file():
            fail.append(f"drawable/{n} is still referenced but res/drawable/{n}.xml does not exist")
        else:
            tag = ET.parse(x).getroot().tag
            if tag not in ("vector", "shape", "layer-list", "inset", "selector"):
                fail.append(f"res/drawable/{n}.xml is a <{tag}>, want a vector/shape drawable")
if fail:
    print("no-pixel-art FAILED:\n- " + "\n- ".join(fail[:60]) + (f"\n... {len(fail) - 60} more" if len(fail) > 60 else ""))
    sys.exit(1)
print("no-pixel-art: source OK")
PY
rm -rf "$B/build/app/outputs/flutter-apk"
(cd "$B" && flutter build apk --debug >"$T/build.log" 2>&1) || die "flutter build apk --debug failed: $(tail -20 "$T/build.log")"
[ -f "$B/build/app/outputs/flutter-apk/app-debug.apk" ] || die "no debug APK"
echo "no-pixel-art OK"
