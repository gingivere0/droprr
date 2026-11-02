#!/usr/bin/env python3
"""Builds Droprr's full-bleed app icons from each theme's logo.

The page fills the whole icon: only the strips beside the arrows are widened, so the
arrows, the folded corner and the colors stay exactly as drawn. The fold shows cream.

Writes, for every theme in design-system/droprr/tokens.json:
  file-swap-icon-pack/themes/<id>/app-icon-1024.png      (opaque square; iOS adds the mask)
  apple/iOS/Assets.xcassets/AppIcon[-<id>].appiconset/app-icon-1024.png
and, for the default theme:
  file-swap-icon-pack/themes/<id>/mac-icon-1024.png       (macOS plate with margin and shadow)
  apple/Mac/Assets.xcassets/AppIcon.appiconset/icon_*.png
  web/icon.png, site/icon.png                             (180 px apple-touch-icon)

Run from the repo root after apple/scripts/generate_theme_logos.swift:
    python3 scripts/make-app-icons.py          (needs numpy, scipy, Pillow)
"""
import json, os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage as nd

S = 1024
CREAM = np.array((244, 246, 241), float)
ROOT = os.getcwd()
P = lambda *p: os.path.join(ROOT, *p)


def full_bleed(logo_path, over=1.10, blend=60):
    im = Image.open(logo_path).convert('RGBA')
    im = im.crop(im.getbbox())
    L = np.array(im).astype(float)
    h, w = L.shape[:2]
    A = L[..., 3] / 255
    # The arrows are the two big holes in the page; keep their columns at a uniform scale.
    filled = nd.binary_fill_holes(A > 0)
    holes = nd.binary_erosion(filled, iterations=2) & (A < 0.5)
    lab, n = nd.label(holes)
    sizes = nd.sum(holes, lab, range(1, n + 1))
    arrows = np.isin(lab, 1 + np.argsort(sizes)[-2:])
    cols = np.nonzero(arrows.any(0))[0]
    a0, a1 = cols.min() - 10, cols.max() + 10
    # Horizontal map: scale k over the arrows, widened (c * k) beside them, blended smoothly.
    k = S * over / h
    x = np.arange(w + 1, dtype=float)
    inside = np.clip(np.minimum(x - a0, a1 - x) / blend + 0.5, 0, 1)
    inside = inside * inside * (3 - 2 * inside)
    c = (h - inside.sum()) / (1 - inside).sum()
    F = np.concatenate([[0], np.cumsum(k * (inside + c * (1 - inside)))[:-1]])
    off = (S - S * over) / 2
    X, Y = np.meshgrid(np.arange(S) + 0.5, np.arange(S) + 0.5)
    sx = np.interp(X - off, F, x) - 0.5
    sy = (Y - off) / k - 0.5
    pre = np.dstack([L[..., :3] * A[..., None], A])
    out = np.dstack([nd.map_coordinates(pre[..., ch], [sy, sx], order=3, mode='constant') for ch in range(4)])
    a = np.clip(out[..., 3], 0, 1)
    # Un-premultiply, then let the page's own colors run into its rounded corners at the icon's
    # edges; only the folded corner (top right) keeps the cream showing through.
    col = out[..., :3] / np.maximum(a, 1e-6)[..., None]
    solid = a > 0.99
    idx = nd.distance_transform_edt(~solid, return_distances=False, return_indices=True)
    edge = col[idx[0], idx[1]]
    outside = nd.binary_dilation(~nd.binary_fill_holes(a > 0.5), iterations=2)
    fill = outside & ~((X > S / 2) & (Y < S / 2))
    a = np.where(fill, 1.0, a)[..., None]
    col = np.where(fill[..., None], edge, col)
    rgb = col * a + CREAM * (1 - a)
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), 'RGB')


def rounded(size, radius, scale=4):
    m = Image.new('L', (size * scale, size * scale), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * scale - 1, size * scale - 1], radius=radius * scale, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def mac_icon(art):
    """macOS doesn't mask icons: the art on an 824 px rounded plate with a soft shadow."""
    plate, x0 = 824, 100
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    m = rounded(plate, 185)
    sh = Image.new('L', (S, S), 0)
    sh.paste(m, (x0, x0 + 10))
    sh = sh.filter(ImageFilter.GaussianBlur(24)).point(lambda v: int(v * 0.3))
    out.paste((0, 0, 0, 255), (0, 0), sh)
    out.paste(art.resize((plate, plate), Image.LANCZOS), (x0, x0), m)
    return out


def main():
    tokens = json.load(open(P('design-system', 'droprr', 'tokens.json')))
    default = tokens['themes']['default']
    for tid in tokens['themes']['order']:
        art = full_bleed(P('file-swap-icon-pack', 'themes', tid, 'logo-1024.png'))
        art.save(P('file-swap-icon-pack', 'themes', tid, 'app-icon-1024.png'))
        ios = 'AppIcon' if tid == default else f'AppIcon-{tid}'
        art.save(P('apple', 'iOS', 'Assets.xcassets', f'{ios}.appiconset', 'app-icon-1024.png'))
        if tid == default:
            mac = mac_icon(art)
            mac.save(P('file-swap-icon-pack', 'themes', tid, 'mac-icon-1024.png'))
            mdir = P('apple', 'Mac', 'Assets.xcassets', 'AppIcon.appiconset')
            for img in json.load(open(os.path.join(mdir, 'Contents.json')))['images']:
                px = int(float(img['size'].split('x')[0]) * int(img['scale'][0]))
                mac.resize((px, px), Image.LANCZOS).save(os.path.join(mdir, img['filename']))
            touch = art.resize((180, 180), Image.LANCZOS)
            touch.save(P('web', 'icon.png'))
            touch.save(P('site', 'icon.png'))
        print('wrote', tid)


if __name__ == '__main__':
    main()
