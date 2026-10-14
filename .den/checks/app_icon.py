"""Launcher-icon acceptance for clarity/app-icon. PROTECTED. Adapted from gym-app's app_icon.py.

    python3 app_icon.py --res budget/android/app/src/main/res --manifest .../AndroidManifest.xml \
        --pubspec budget/pubspec.yaml [--apk APK --aapt2 PATH]

Brian, 2026-10-14: "Can you fix the clarity icon? ... poor masking and purple background but white
square corners in it ... We have new icon sets, we should use those." The art is hanquest-images'
icons/app/clarity/ic_launcher_{fg,bg,mono}.png, read from that repo's COMMITTED origin/red-dev
(never its working tree). Source tree:
  1. res/drawable-nodpi/ic_launcher_{fg,bg,mono}.png byte-identical to the art;
  2. mipmap-anydpi-v26/ic_launcher.xml and ic_launcher_round.xml: <adaptive-icon> with background
     @drawable/ic_launcher_bg, foreground @drawable/ic_launcher_fg, monochrome
     @drawable/ic_launcher_mono, and no <inset> (the old icon was a square inset into the mask);
  3. legacy mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher{,_round}.png at 48..192 px drawn from the art;
  4. <application android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher_round">;
  5. the old white-cornered art is gone: no res/**/ic_launcher_foreground.png, no #433187 in res/
     or pubspec.yaml (flutter_launcher_icons would regenerate the old icon from it);
APK (--apk): badging's application icon is the adaptive xml (aapt2 badging ALWAYS resolves an
adaptive icon to that xml, at every density: den-local-ai 757d209), its xmltree names a
foreground, background AND monochrome, and the foreground PNG found through the resource table
(release builds shorten paths, so never by name) is byte-identical to the art, with its corners
and everything outside the 66 dp safe circle transparent.
"""
import argparse
import io
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

A = "{http://schemas.android.com/apk/res/android}"
IMAGES = Path(os.environ.get("HANQUEST_IMAGES", Path.home() / "projects/hanquest-images"))
REF = "origin/red-dev"
ICON = "clarity"
LAYERS = ("fg", "bg", "mono")
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

ap = argparse.ArgumentParser()
ap.add_argument("--res", required=True)
ap.add_argument("--manifest", required=True)
ap.add_argument("--pubspec", required=True)
ap.add_argument("--apk")
ap.add_argument("--aapt2")
a = ap.parse_args()
res, fail = Path(a.res), []


def die(msg):
    sys.exit(f"FAIL: {msg}")


def outside_safe(im):
    """(opaque samples outside the 66/108 safe circle, inside it, corner max alpha)."""
    im = im.convert("RGBA").resize((432, 432))
    px = im.getchannel("A").load()
    out = inside = 0
    for y in range(0, 432, 2):
        for x in range(0, 432, 2):
            if px[x, y] > 32:
                if (x - 216) ** 2 + (y - 216) ** 2 > 132 ** 2:
                    out += 1
                else:
                    inside += 1
    corners = max(px[x, y] for x in (0, 1, 430, 431) for y in (0, 1, 430, 431))
    return out, inside, corners


# 0. the art, from hanquest-images' committed red-dev
subprocess.run(["git", "-C", str(IMAGES), "fetch", "-q", "origin", "red-dev"], capture_output=True, timeout=120)
tmp = Path(tempfile.mkdtemp())
art = {}
for layer in LAYERS:
    p = f"icons/app/{ICON}/ic_launcher_{layer}.png"
    r = subprocess.run(["git", "-C", str(IMAGES), "show", f"{REF}:{p}"], capture_output=True)
    if r.returncode != 0:
        die(f"hanquest-images has no {p} on {REF} yet (its app-icon-clarity task renders it first)")
    (tmp / f"{layer}.png").write_bytes(r.stdout)
    art[layer] = r.stdout
composite = Image.alpha_composite(Image.open(tmp / "bg.png").convert("RGBA"),
                                  Image.open(tmp / "fg.png").convert("RGBA")).convert("RGB")

# 1. the layers, byte for byte
for layer in LAYERS:
    f = res / "drawable-nodpi" / f"ic_launcher_{layer}.png"
    if not f.is_file():
        fail.append(f"missing {f}")
    elif f.read_bytes() != art[layer]:
        fail.append(f"{f} differs from hanquest-images {REF}:icons/app/{ICON}/ic_launcher_{layer}.png")

# 2. adaptive icon XML: three layers, no inset
for n in ("ic_launcher", "ic_launcher_round"):
    f = res / "mipmap-anydpi-v26" / f"{n}.xml"
    if not f.is_file():
        fail.append(f"missing {f}")
        continue
    root = ET.parse(f).getroot()
    want = {"background": "@drawable/ic_launcher_bg", "foreground": "@drawable/ic_launcher_fg",
            "monochrome": "@drawable/ic_launcher_mono"}
    if root.tag != "adaptive-icon":
        fail.append(f"{f} is not an <adaptive-icon>")
        continue
    for tag, d in want.items():
        e = root.find(tag)
        if e is None or e.get(A + "drawable") != d:
            fail.append(f"{f}: <{tag} android:drawable=\"{d}\"/> is missing")
    if root.find(".//inset") is not None:
        fail.append(f"{f} still wraps a layer in <inset>: the art is already laid out in the safe zone")

# 3. legacy PNGs drawn from the same art
for dpi, px in LEGACY.items():
    for n in ("ic_launcher", "ic_launcher_round"):
        f = res / f"mipmap-{dpi}" / f"{n}.png"
        if not f.is_file():
            fail.append(f"missing {f}")
            continue
        im = Image.open(f)
        if im.size != (px, px):
            fail.append(f"{f} is {im.size}, want {px}x{px}")
            continue
        got = Image.alpha_composite(Image.new("RGBA", im.size, (0, 0, 0, 255)), im.convert("RGBA")).convert("RGB")
        c = (px // 4, px // 4, 3 * px // 4, 3 * px // 4)
        diff = min(sum(ImageStat.Stat(ImageChops.difference(
            got.crop(c), composite.crop((i, i, 432 - i, 432 - i)).resize((px, px)).crop(c))).mean) / 3
            for i in (0, 18, 36, 54, 72))
        if diff > 40:
            fail.append(f"{f} does not look like icons/app/{ICON} (centre mean diff {diff:.0f})")

# 4. the manifest
app = ET.parse(a.manifest).getroot().find("application")
if app is None or app.get(A + "icon") != "@mipmap/ic_launcher" or app.get(A + "roundIcon") != "@mipmap/ic_launcher_round":
    fail.append(f'{a.manifest}: <application> needs android:icon="@mipmap/ic_launcher" '
                'android:roundIcon="@mipmap/ic_launcher_round"')

# 5. the old art is gone
stale = sorted(str(p.relative_to(res)) for p in res.glob("*/ic_launcher_foreground.png"))
if stale:
    fail.append(f"the old white-cornered foreground is still in res/: {stale}")
for f in [*res.rglob("*.xml"), Path(a.pubspec)]:
    if re.search(r"433187", f.read_text(errors="replace"), re.I):
        fail.append(f"{f} still carries the old purple #433187")

# 6. the built APK
if a.apk and not fail:
    ap2 = a.aapt2
    b = subprocess.run([ap2, "dump", "badging", a.apk], capture_output=True, text=True).stdout
    line = next((l for l in b.splitlines() if l.startswith("application:")), "")
    icon = line.split("icon='")[1].split("'")[0] if "icon='" in line else ""
    if not icon.endswith(".xml"):
        fail.append(f"{a.apk}: application icon {icon!r} is not the adaptive icon xml")
    else:
        t = subprocess.run([ap2, "dump", "xmltree", "--file", icon, a.apk], capture_output=True, text=True).stdout
        for tag in ("adaptive-icon", "background", "foreground", "monochrome"):
            if f"E: {tag}" not in t:
                fail.append(f"{a.apk}: {icon} has no <{tag}>")
        if "E: inset" in t:
            fail.append(f"{a.apk}: {icon} still uses <inset>")
        rt = subprocess.run([ap2, "dump", "resources", a.apk], capture_output=True, text=True).stdout
        m = re.search(r"drawable/ic_launcher_fg\n(?:\s+\(.*\) \(file\) (\S+) type=PNG\n?)+", rt)
        files = re.findall(r"\(file\) (\S+) type=PNG", m.group(0)) if m else []
        if not files:
            fail.append(f"{a.apk}: no drawable/ic_launcher_fg PNG in the resource table")
        z = zipfile.ZipFile(a.apk)
        for fpath in files:
            data = z.read(fpath)
            if data != art["fg"]:
                # aapt2 may crunch PNGs: compare pixels, not bytes
                d = ImageChops.difference(Image.open(io.BytesIO(data)).convert("RGBA"),
                                          Image.open(tmp / "fg.png").convert("RGBA").resize(Image.open(io.BytesIO(data)).size))
                if max(e[1] for e in d.getextrema()) > 8:
                    fail.append(f"{a.apk}: {fpath} is not hanquest-images' clarity foreground")
            out, inside, corners = outside_safe(Image.open(io.BytesIO(data)))
            if corners > 8 or out > 0.02 * max(inside, 1):
                fail.append(f"{a.apk}: foreground {fpath} is opaque outside the safe zone "
                            f"(corner alpha {corners}, {out} samples outside vs {inside} inside): masks will show its edges")
        if not fail:
            print(f"apk: {icon} adaptive (fg/bg/monochrome), foreground {files} transparent outside the safe zone")

if fail:
    print(f"app icon ({ICON}) FAILED:\n- " + "\n- ".join(fail))
    sys.exit(1)
print(f"app icon OK: {ICON} installed from hanquest-images {REF}")
