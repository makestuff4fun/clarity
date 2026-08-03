#!/usr/bin/env python3
"""Turn the 1024px pixel-art masters into the app's icon/illustration assets.

The masters are drawn on a flat white background with a soft drop shadow. Three
things have to happen: knock the background out, crop to the artwork so it fills
its circle in the UI, and downscale to the size each slot expects.

Naive "flood fill everything white from the border" destroys artwork that is
itself white (paper money, a bank's marble facade) whenever the outline has a
one-pixel gap for the fill to leak through. So the background mask is eroded
before it is labelled: a narrow bridge between the outside and an interior white
region is severed, the interior survives as its own component, and dilating the
surviving border components back recovers the eroded edge.

Usage: python3 tool/process_pixel_art.py <masters-dir>
"""

import os
import re
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

# Most artwork is outlined darkly enough that a generous background test — light
# and close to neutral — lifts off the page and its soft shadow in one go.
BG_MIN_BRIGHTNESS = 175
BG_MAX_CHROMA = 45
# Artwork that is itself white (paper money, cheques, forms) is drawn with
# outlines barely tinted away from the page, so the generous test eats it. Those
# fall back to lifting only near-pure white, then clearing the neutral shadow
# that is left behind.
PAGE_MIN_BRIGHTNESS = 246
PAGE_MAX_CHROMA = 8
SHADOW_MIN_BRIGHTNESS = 215
SHADOW_MAX_CHROMA = 6
# If the generous test keeps less than this share of what the strict test keeps,
# it ate the artwork.
RUINED_BELOW = 0.55
# Bridges up to 2*SEAL px wide are treated as outline gaps, not real openings.
SEAL = 2
# Detached blobs smaller than this are artifacts; confetti flakes are bigger.
MIN_BLOB_PX = 120
# Breathing room around the artwork once cropped, as a fraction of its long side.
MARGIN = 0.02


def flood_from_border(candidate):
    """The part of `candidate` reachable from outside the image.

    Eroding first severs one-pixel gaps in an outline, so a white region walled
    off by artwork stays put instead of draining out through the leak.
    """
    # border_value=1 keeps the image edge itself background, so the outside
    # region survives erosion and can still be found by the border test below.
    sealed = ndimage.binary_erosion(candidate, iterations=SEAL, border_value=1)
    labels, count = ndimage.label(sealed)
    if not count:
        return np.zeros_like(candidate)
    edge = np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]])
    outside = np.isin(labels, np.unique(edge[edge != 0]))
    # Give back the pixels erosion ate, without crossing into sealed-off regions.
    return ndimage.binary_dilation(outside, iterations=SEAL) & candidate


def alpha_for(img):
    """Alpha channel for an RGB master: 0 where the flat background is."""
    mx = img.max(axis=2)
    mn = img.min(axis=2)
    chroma = mx - mn

    outside = flood_from_border(
        (mn > BG_MIN_BRIGHTNESS) & (chroma < BG_MAX_CHROMA))

    page = flood_from_border(
        (mn >= PAGE_MIN_BRIGHTNESS) & (chroma <= PAGE_MAX_CHROMA))
    if (~outside).sum() < RUINED_BELOW * (~page).sum():
        # White-on-white artwork: keep the strict cut, then take the drop
        # shadow, which is neutral grey and only ever touches the page.
        shadow = (~page) & (chroma <= SHADOW_MAX_CHROMA) & \
            (mn >= SHADOW_MIN_BRIGHTNESS)
        outside = page | ndimage.binary_propagation(
            ndimage.binary_dilation(page) & shadow, mask=shadow)

    alpha = np.where(outside, 0, 255).astype(np.uint8)

    blobs, n = ndimage.label(alpha > 0)
    if n > 1:
        sizes = ndimage.sum(alpha > 0, blobs, range(1, n + 1))
        for blob_id, size in enumerate(sizes, start=1):
            if size < MIN_BLOB_PX:
                alpha[blobs == blob_id] = 0
    return alpha


def cutout(path):
    """Load a master, knock out its background, and crop to the artwork."""
    img = np.array(Image.open(path).convert('RGB'), dtype=np.int16)
    alpha = alpha_for(img)

    rows, cols = np.where(alpha > 0)
    if len(rows):
        img = img[rows.min():rows.max() + 1, cols.min():cols.max() + 1]
        alpha = alpha[rows.min():rows.max() + 1, cols.min():cols.max() + 1]

    height, width = alpha.shape
    side = int(max(height, width) * (1 + MARGIN))
    rgb = np.zeros((side, side, 3), dtype=np.uint8)
    a = np.zeros((side, side), dtype=np.uint8)
    top, left = (side - height) // 2, (side - width) // 2
    rgb[top:top + height, left:left + width] = img.astype(np.uint8)
    a[top:top + height, left:left + width] = alpha
    return Image.fromarray(np.dstack([rgb, a]), 'RGBA')


def write(image, path, size):
    image.resize((size, size), Image.LANCZOS).save(path)


def main(masters):
    app = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    asset = lambda *p: os.path.join(app, *p)
    master = lambda name: os.path.join(masters, name + '.png')

    written = 0
    for filename in sorted(os.listdir(masters)):
        if not filename.endswith('.png'):
            continue
        # Cashew named its variants "taxi(1).png"; the masters use "taxi_1.png".
        name = re.sub(r'_(\d)\.png$', r'(\1).png', filename)
        write(cutout(os.path.join(masters, filename)),
              asset('assets', 'categories', name), 128)
        written += 1
    print('category icons:', written)

    for target, source in {'Graph': 'increase',
                           'BankOrPig': 'savings-jar',
                           'PigBank': 'treasure-chest'}.items():
        write(cutout(master(source)),
              asset('assets', 'landing', target + '.png'), 512)

    ghost, binoculars = cutout(master('ghost')), cutout(master('binoculars'))
    for name in ['empty', 'empty-filter', 'empty-old', 'empty-old-filter']:
        write(ghost, asset('assets', 'images', name + '.png'), 512)
    for name in ['no-search', 'no-search-filter']:
        write(binoculars, asset('assets', 'images', name + '.png'), 512)

    write(cutout(master('firework')),
          asset('assets', 'icons', 'fun', 'party-hat.png'), 256)
    write(cutout(master('candy-cane')),
          asset('assets', 'icons', 'fun', 'santa-hat.png'), 256)

    drawable = asset('android', 'app', 'src', 'main', 'res', 'drawable')
    for target, source in {'piggybank': 'piggy-bank',
                           'addtransaction': 'coin',
                           'transfertransaction': 'contactless-payment',
                           'net_worth_widget': 'coin-stack',
                           'net_worth_plus_widget': 'coin-stack',
                           'plus_widget': 'coin',
                           'transfer_widget': 'contactless-payment'}.items():
        write(cutout(master(source)),
              os.path.join(drawable, target + '.png'), 512)

    # Android tints notification icons, so they ship as white silhouettes.
    stack = np.array(cutout(master('coin-stack')).resize((128, 128),
                                                         Image.LANCZOS))[..., 3]
    silhouette = Image.fromarray(
        np.dstack([np.full_like(stack, 255)] * 3 + [stack]), 'RGBA')
    for path in [asset('assets', 'icon', 'notification_icon_android.png'),
                 asset('assets', 'icon', 'notification_icon_android2.png'),
                 os.path.join(drawable, 'notification_icon_android2.png')]:
        silhouette.save(path)
    print('illustrations, widget art and notification icons written')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1
         else '/home/bairui/projects/hanquest-images/clarity/full')
