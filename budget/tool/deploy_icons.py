#!/usr/bin/env python3
"""Install the judged 479-icon set into budget/assets/categories/.

    deploy_icons.py            # dry run, changes nothing
    deploy_icons.py --apply

Source is `/srv/outputs/clarity_icons/cut/outline_fixed/<name>_<seed>.png`, per
hanquest-images/requests/clarity-icon-handoff.md. Three things there are not
guessable and are the reason this is a script rather than a cp:

1. WHICH VARIANT IS CANONICAL IS RECORDED, NOT INFERRABLE. Every icon has a
   `_72000` roll; nine have a different canonical variant because Brian picked a
   re-roll. The authority is rerolls.json's `keeps`. `cut/outline` also holds
   nine strays at non-72000 seeds that were never re-rolls, so "highest seed
   wins" or "newest file wins" would silently ship the wrong picture for icons
   nobody would think to check.

2. THE FILENAME CONVENTIONS DIFFER. The app stores `atm-machine(1).png`; the
   renders are `atm-machine_1.png`. Same transform process_pixel_art.py already
   does in the other direction.

3. air-hockey IS NOW ping-pong. Brian renamed the slot on 2026-09-09 — the model
   kept drawing a ping-pong paddle, so he changed the word rather than the
   picture. A category's iconName is a STORED FILENAME, so a rename orphans any
   database row holding the old one. Verified safe here: zero `air-hockey`
   references in the v48 backup, and Clarity ships nowhere, so there is no other
   user's data. iconObjects.dart is updated separately.
"""
import argparse, json, os, re, shutil, sys
from PIL import Image

SRC = "/srv/outputs/clarity_icons/cut/outline_fixed"
KEEPS = "/srv/outputs/clarity_icons/rerolls.json"
DST = "/home/bairui/projects/clarity/budget/assets/categories"
RENAME = {"air-hockey": "ping-pong"}          # app name -> render name


def render_to_app(name):
    """`atm-machine_1` -> `atm-machine(1)`; everything else unchanged."""
    return re.sub(r"_(\d)$", r"(\1)", name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    keeps = json.load(open(KEEPS)).get("keeps", {})
    if not keeps:
        sys.exit("rerolls.json has no 'keeps' — refusing to guess canonical variants")

    have = {}
    for f in os.listdir(SRC):
        m = re.match(r"(.+)_(\d+)\.png$", f)
        if m:
            have.setdefault(m.group(1), {})[int(m.group(2))] = f

    chosen, problems = {}, []
    for name, seeds in have.items():
        want = int(keeps.get(name, 72000))
        if want not in seeds:
            problems.append(f"{name}: wanted seed {want}, have {sorted(seeds)}")
            continue
        chosen[render_to_app(name)] = os.path.join(SRC, seeds[want])
    if problems:
        sys.exit("unresolvable canonical variants:\n  " + "\n  ".join(problems))

    app = {f[:-4] for f in os.listdir(DST) if f.endswith(".png")}
    new = set(chosen)
    added, removed = sorted(new - app), sorted(app - new)

    expect_add = sorted(RENAME.values())
    expect_del = sorted(RENAME.keys())
    if added != expect_add or removed != expect_del:
        sys.exit(f"name drift beyond the known rename.\n  added:   {added}\n"
                 f"  removed: {removed}\n  expected +{expect_add} -{expect_del}")

    # Every source must be a real 128x128 RGBA with something in it. A file that
    # keyed to nothing is still a valid png and would ship as an invisible icon.
    bad = []
    for n, p in sorted(chosen.items()):
        im = Image.open(p)
        if im.size != (128, 128) or im.mode != "RGBA":
            bad.append(f"{n}: {im.size} {im.mode}")
            continue
        if im.getchannel("A").getbbox() is None:
            bad.append(f"{n}: fully transparent")
    if bad:
        sys.exit("bad source images:\n  " + "\n  ".join(bad))

    print(f"{len(chosen)} icons resolve cleanly, all 128x128 RGBA and non-empty")
    print(f"  re-rolls taken from rerolls.json: "
          + ", ".join(f"{k}={v}" for k, v in sorted(keeps.items())))
    print(f"  rename: -{expect_del[0]}.png  +{expect_add[0]}.png")
    print(f"  {len(new & app)} filenames replaced in place")
    if not a.apply:
        print("\nDRY RUN — nothing written. Re-run with --apply")
        return

    for n, p in chosen.items():
        shutil.copyfile(p, os.path.join(DST, n + ".png"))
    for n in removed:
        os.remove(os.path.join(DST, n + ".png"))
    final = {f[:-4] for f in os.listdir(DST) if f.endswith(".png")}
    assert final == new, f"post-copy mismatch: {sorted(final ^ new)}"
    print(f"\nwrote {len(chosen)} icons to {DST}; directory now holds {len(final)}")


if __name__ == "__main__":
    main()
