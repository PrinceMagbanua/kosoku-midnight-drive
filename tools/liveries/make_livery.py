"""Generates Kosoku's original car liveries (vinyl textures).

Format (same as the pack's existing vinyls): a 4096x4096 RGB PNG whose top
half is the painted body and whose bottom half is the shared detail atlas
(lights, grilles, plates, interior...) copied unchanged from a palette atlas.
Plus a 256x128 thumbnail of the top half in textures/thumbs/.

Body UV layout (top half, u = x, v = y, both 0..1 of the full texture), the
same convention on every modular car:
  - u runs front (u ~ 0) to rear (u ~ 1).
  - v = 0.25 is the car's centreline. The middle of the top half is a
    top-down plan of the bonnet/roof/boot; the strips above and below are
    the two flanks, roofline towards the middle, sills towards the edges.
  - The lower flank reads upright; the upper flank is upside down, so text
    painted there is rotated 180 degrees (the old vinyls' "66"/"99" trick).
Because the exact panel shapes differ per car, designs are drawn as bands
measured from the centreline (d = |v - 0.25|), so they land on the same
part of every car.

Usage: python3 tools/liveries/make_livery.py <livery_id>   (see LIVERIES)
"""
import hashlib
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TEX_DIR = os.path.join(ROOT, "assets/cars/Kosoku_Cars_GLB/textures")
THUMB_DIR = os.path.join(TEX_DIR, "thumbs")
FONT_DISPLAY = os.path.join(ROOT, "FONT/KosokuDisplay/KosokuDisplay-Regular.ttf")
FONT_NUMBER = os.path.join(ROOT, "FONT/Exo2/Exo2-VariableFont_wght.ttf")
# Bottom half (detail atlas) is copied from here.
DETAIL_SOURCE = "PolygonStreetRacer_Texture_01_A.png"

SIZE = 4096
SS = 2  # supersampling factor for the body half
W, H = SIZE * SS, SIZE // 2 * SS  # body canvas


def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def px(u, v):
    """UV (0..1 of the full texture, v only within the top half) -> canvas."""
    return (u * W, v * 2 * H)


def mirror_poly(points_ud):
    """points in (u, d) where d = distance from the centreline towards the
    sills. Returns both flanks / both halves of the plan as canvas polygons."""
    upper = [px(u, 0.25 - d) for u, d in points_ud]
    lower = [px(u, 0.25 + d) for u, d in points_ud]
    return upper, lower


def poly_both(draw, points_ud, fill):
    for p in mirror_poly(points_ud):
        draw.polygon(p, fill=fill)


def band(u0, u1, d0_a, d1_a, d0_b, d1_b, steps=24):
    """A band running from u0 to u1 whose inner/outer edge (d0/d1) move
    linearly from the _a values to the _b values (sweeps up or down)."""
    inner, outer = [], []
    for i in range(steps + 1):
        t = i / steps
        u = u0 + (u1 - u0) * t
        inner.append((u, d0_a + (d0_b - d0_a) * t))
        outer.append((u, d1_a + (d1_b - d1_a) * t))
    return inner + outer[::-1]


def gradient(c_front, c_rear, c_edge):
    """Base coat: front-to-rear blend, darkening towards the sills."""
    x = np.linspace(0.0, 1.0, W)[None, :, None]
    row = np.array(c_front, float) + (np.array(c_rear, float) - np.array(c_front, float)) * x
    d = np.abs(np.linspace(0.0, 0.5, H) - 0.25)[:, None, None] / 0.25  # 0 centre .. 1 sill
    t = np.clip((d - 0.55) / 0.45, 0.0, 1.0) ** 1.5 * 0.6
    arr = row + (np.array(c_edge, float) - row) * t
    return Image.fromarray(arr.round().astype(np.uint8), "RGB")


def text_on_flanks(img, text, font_path, size_uv, u, d, fill, outline=None,
                   outline_w=0, plate=None, plate_pad=0.25, weight=None):
    """Draws `text` centred at (u, d) on both flanks - upright on the lower
    flank, rotated 180 on the upper one. size_uv = cap height in UV units."""
    size = int(size_uv * 2 * H)
    font = ImageFont.truetype(font_path, size)
    if weight is not None:
        try:
            font.set_variation_by_axes([weight])
        except Exception:
            pass
    tmp = Image.new("RGBA", (1, 1))
    bbox = ImageDraw.Draw(tmp).textbbox((0, 0), text, font=font, stroke_width=outline_w)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = int(th * plate_pad) if plate else 0
    tile = Image.new("RGBA", (tw + pad * 2, th + pad * 2), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    if plate:
        r = int(min(tile.size) * 0.18)
        td.rounded_rectangle((0, 0, tile.size[0] - 1, tile.size[1] - 1), r, fill=plate)
    td.text((pad - bbox[0], pad - bbox[1]), text, font=font, fill=fill,
            stroke_width=outline_w, stroke_fill=outline)
    for flank, t in (("lower", tile), ("upper", tile.rotate(180))):
        cx, cy = px(u, 0.25 + d if flank == "lower" else 0.25 - d)
        img.alpha_composite(t, (int(cx - t.size[0] / 2), int(cy - t.size[1] / 2)))


# --- liveries --------------------------------------------------------------

def midnight_volt():
    """01 - Midnight Volt: midnight-indigo base, an electric cyan speed slash
    sweeping up each flank with a hot-pink trailing pinstripe, twin cyan
    stripes over bonnet/roof/boot, white door numbers and a KOSOKU wordmark
    on the rear quarters."""
    navy_front = hexrgb("#141a4a")
    navy_rear = hexrgb("#0b0e2b")
    sill = hexrgb("#05060f")
    cyan = hexrgb("#29e6ff")
    cyan_deep = hexrgb("#0f8fd6")
    pink = hexrgb("#ff2e88")
    white = hexrgb("#f4f7ff")
    ink = hexrgb("#0a0c1e")

    img = gradient(navy_front, navy_rear, sill).convert("RGBA")
    d = ImageDraw.Draw(img)

    # Plan view: broad deep-blue centre band edged by two thin cyan stripes,
    # bonnet to boot.
    poly_both(d, band(0.0, 1.0, 0.0, 0.034, 0.0, 0.034), cyan_deep + (255,))
    poly_both(d, band(0.0, 1.0, 0.040, 0.050, 0.040, 0.050), cyan + (255,))

    # Flanks: the speed slash. Wide at the front wheel near the sill, rising
    # and tapering towards the rear shoulder (roofline side), then a pink
    # pinstripe tracing its lower edge, and a dark undercut for contrast.
    # Kept inside d ~0.15-0.23: the door band every car shares (the AE86's
    # doors sit highest, ~0.14-0.20).
    slash = band(0.02, 0.98, 0.195, 0.225, 0.148, 0.160)
    under = band(0.02, 0.98, 0.225, 0.236, 0.160, 0.166)
    pin = band(0.06, 0.98, 0.236, 0.242, 0.166, 0.169)
    poly_both(d, under, ink + (255,))
    poly_both(d, slash, cyan + (255,))
    poly_both(d, pin, pink + (255,))
    # Inner gradient on the slash: deeper blue towards the front.
    poly_both(d, band(0.02, 0.45, 0.195, 0.211, 0.175, 0.186), cyan_deep + (255,))

    # Shards breaking off the slash near the rear.
    for i, (u, w, dd) in enumerate([(0.80, 0.035, 0.185), (0.86, 0.025, 0.193), (0.905, 0.018, 0.200)]):
        poly_both(d, [(u, dd), (u + w, dd - 0.006), (u + w * 0.6, dd + 0.010)], (cyan if i % 2 == 0 else pink) + (255,))

    # Door number and rear-quarter wordmark (both flanks; text helper handles
    # the upside-down upper flank).
    # The number sits low on the front door, clear of the window line on the
    # shorter-flanked cars (AE86); the wordmark rides inside the slash on the
    # rear door, where every car has a flat panel.
    text_on_flanks(img, "08", FONT_NUMBER, 0.022, 0.40, 0.172, ink + (255,),
                   plate=white + (255,), plate_pad=0.28, weight=900)
    text_on_flanks(img, "KOSOKU", FONT_DISPLAY, 0.0105, 0.585, 0.1775, ink + (255,))

    return img.convert("RGB")


LIVERIES = {
    "01": ("Kosoku_Veh_Tex_01_Midnight_Volt.png", midnight_volt),
}


def _uid():
    chars = "abcdefghijklmnopqrstuvwxyz012345678"  # Godot's ResourceUID alphabet
    return "uid://" + "".join(random.choice(chars) for _ in range(13))


def write_import(png_path, thumb):
    """Writes the .import next to a new PNG (copying an existing livery's
    import settings) so Godot picks it up with the right compression. Kept
    as-is if one already exists, so the uid stays stable on rebuilds."""
    imp = png_path + ".import"
    if os.path.exists(imp):
        return
    res = "res://" + os.path.relpath(png_path, ROOT).replace(os.sep, "/")
    base = os.path.basename(png_path)
    h = hashlib.md5(res.encode()).hexdigest()
    ref_dir = THUMB_DIR if thumb else TEX_DIR
    ref = open(os.path.join(ref_dir, "PolygonStreetRacer_Veh_Tex_01_Race_Purple.png.import")).read()
    params = ref[ref.index("[params]"):]
    ext = "ctex" if thumb else "s3tc.ctex"
    key = "path" if thumb else "path.s3tc"
    meta = '"vram_texture": false' if thumb else '"imported_formats": ["s3tc_bptc"],\n"vram_texture": true'
    dest = f"res://.godot/imported/{base}-{h}.{ext}"
    with open(imp, "w") as f:
        f.write(f'[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\nuid="{_uid()}"\n'
                f'{key}="{dest}"\nmetadata={{\n{meta}\n}}\n\n[deps]\n\n'
                f'source_file="{res}"\ndest_files=["{dest}"]\n\n{params}')


def build(livery_id):
    name, fn = LIVERIES[livery_id]
    body = fn().resize((SIZE, SIZE // 2), Image.LANCZOS)
    detail = Image.open(os.path.join(TEX_DIR, DETAIL_SOURCE)).convert("RGB")
    out = Image.new("RGB", (SIZE, SIZE))
    out.paste(body, (0, 0))
    out.paste(detail.crop((0, SIZE // 2, SIZE, SIZE)), (0, SIZE // 2))
    out.save(os.path.join(TEX_DIR, name), optimize=True)
    body.resize((256, 128), Image.LANCZOS).save(os.path.join(THUMB_DIR, name), optimize=True)
    write_import(os.path.join(TEX_DIR, name), thumb=False)
    write_import(os.path.join(THUMB_DIR, name), thumb=True)
    print("wrote", name)
    return name


if __name__ == "__main__":
    for lid in (sys.argv[1:] or LIVERIES.keys()):
        build(lid)
