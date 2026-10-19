"""Generate Android launcher resources for Branding 1.0.

The approved source is the flat PNG in ``docs/branding/original_app_icon.png``.
It is never modified. This script derives:

* legacy launcher icons (48..192 px, including a round variant),
* adaptive-icon background / foreground / monochrome layers (108 dp at every
  density), and
* local previews used by the Branding 1.0 report.

The foreground keeps the approved pin composition (gold pin, architecture,
bridge, water and pale-blue detail arcs) and places it inside the 66 dp safe
circle of the 108 dp adaptive layer. The legacy icon reconstructs the blue
gradient behind the source's white rounded corners so no white edge remains.

Run from anywhere:

    python tool/generate_branding_icons.py
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "docs" / "branding" / "original_app_icon.png"
RES = REPO / "android" / "app" / "src" / "main" / "res"
PREVIEWS = REPO / "docs" / "branding" / "previews"

LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
ADAPTIVE_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}
ADAPTIVE_CANVAS = 1080  # 10 px per dp in the 108 dp layer.
SAFE_RADIUS = ADAPTIVE_CANVAS * 33 / 108  # 66 dp safe circle.
SAFE_FILL = 0.98


def _tint(rgba: Image.Image, color: tuple[int, int, int, int]) -> Image.Image:
    tinted = Image.new("RGBA", rgba.size, color)
    tinted.putalpha(rgba.getchannel("A"))
    return tinted


def _save_downsized(master: Image.Image, target: Path, size: int) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    master.resize((size, size), Image.Resampling.LANCZOS).save(target, "PNG")


def _circle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    radius = size / 2 - 2
    ImageDraw.Draw(mask).ellipse(
        [size / 2 - radius, size / 2 - radius,
         size / 2 + radius, size / 2 + radius],
        fill=255,
    )
    return mask


def _squircle_mask(size: int) -> Image.Image:
    yy, xx = np.mgrid[0:size, 0:size]
    half = size * 72 / 108 / 2
    x = (xx - (size - 1) / 2) / half
    y = (yy - (size - 1) / 2) / half
    return Image.fromarray(
        np.clip((1 - (np.abs(x) ** 4 + np.abs(y) ** 4)) * 255 * 8, 0, 255)
        .astype(np.uint8),
        "L",
    )


def build_masters() -> dict[str, Image.Image]:
    if not SOURCE.exists():
        raise SystemExit(
            f"Approved source icon is missing: {SOURCE}. "
            "Do not substitute a different image; restore the approved PNG."
        )

    raw = Image.open(SOURCE).convert("RGB")
    im = np.asarray(raw).astype(np.float64)
    h, w, _ = im.shape
    if h != w:
        raise SystemExit(f"Approved icon must be square, got {w}x{h}.")
    yy, xx = np.mgrid[0:h, 0:w]
    xn = (xx - (w - 1) / 2) / ((w - 1) / 2)
    yn = (yy - (h - 1) / 2) / ((h - 1) / 2)
    r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    white = (r > 242) & (g > 242) & (b > 242)
    blue = (b > r + 20) & (b > 55) & ~white

    # Fit the blue field from the border, excluding the central top column where
    # the spire reaches the edge. A cubic polynomial captures the smooth
    # diagonal/radial gradient without inventing visible bands.
    band = (xx < 220) | (xx >= w - 220) | (yy < 220) | (yy >= h - 220)
    band &= ~((yy < 220) & (xx > 250) & (xx < 1000))
    sample = band & blue
    features = [
        np.ones_like(xn), xn, yn, xn * xn, xn * yn, yn * yn,
        xn ** 3, xn * xn * yn, xn * yn * yn, yn ** 3,
    ]
    a = np.stack([f[sample] for f in features], axis=1)
    coeff = np.stack(
        [np.linalg.lstsq(a, im[:, :, c][sample], rcond=None)[0]
         for c in range(3)],
        axis=1,
    )
    full = np.stack([f.ravel() for f in features], axis=1)
    background = np.clip((full @ coeff).reshape(h, w, 3), 0, 255)

    gold = (r > 115) & (g > 65) & (b < 205) & (r > b + 22) & (g > b - 5)
    lightblue = (b > 165) & (g > 115) & (r < 185) & (b > r + 35) & (g > r + 20)
    central = (xx > 150) & (xx < w - 150) & (yy > 50) & (yy < h - 50)
    gold &= central
    lightblue &= central

    labels, count = ndimage.label(gold, structure=np.ones((3, 3)))
    sizes = ndimage.sum(gold, labels, range(1, count + 1))
    order = np.argsort(sizes)[::-1]
    pin = ndimage.binary_closing(labels == (int(order[0]) + 1), structure=np.ones((5, 5)))
    pin = ndimage.binary_fill_holes(pin)
    ys, xs = np.where(pin)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    for i in order[1:]:
        comp = int(i) + 1
        cys, cxs = np.where(labels == comp)
        if (
            sizes[i] >= 8
            and cxs.min() >= x0 - 3 and cxs.max() <= x1 + 3
            and cys.min() >= y0 - 3 and cys.max() <= y1 + 3
        ):
            pin |= ndimage.binary_fill_holes(labels == comp)
    pin = ndimage.binary_fill_holes(pin)

    # Foreground: the approved pin silhouette on transparency. The blue inside
    # the gold ring is part of the approved composition and is kept.
    fg_alpha = ndimage.binary_dilation(pin, structure=np.ones((3, 3)), iterations=1)
    fg_alpha = np.clip(ndimage.gaussian_filter(fg_alpha.astype(np.float32), sigma=1.2), 0, 1)
    fg_alpha[fg_alpha < 0.02] = 0
    foreground = Image.fromarray(
        np.dstack([im, fg_alpha * 255]).astype(np.uint8), "RGBA"
    )

    # Legacy: remove the source's light antialiased rim, then reconstruct the
    # gradient outside the rounded-square silhouette.
    nonwhite = ~white
    nlbl, _ = ndimage.label(nonwhite, structure=np.ones((3, 3)))
    icon_shape = ndimage.binary_fill_holes(nlbl == nlbl[h // 2, w // 2])
    icon_shape = ndimage.binary_erosion(icon_shape, structure=np.ones((3, 3)), iterations=6)
    full_bleed = im.copy()
    full_bleed[~icon_shape] = background[~icon_shape]
    legacy_alpha = np.clip(
        ndimage.gaussian_filter(icon_shape.astype(np.float32), sigma=0.8), 0, 1
    )
    legacy = Image.fromarray(
        np.dstack([full_bleed, legacy_alpha * 255]).astype(np.uint8), "RGBA"
    )
    round_icon = Image.fromarray(
        np.dstack([full_bleed, np.asarray(_circle_mask(w))]).astype(np.uint8),
        "RGBA",
    )

    # Monochrome: the pin's gold structure plus the pale-blue arcs that sit
    # inside it. Tiny detached specks are removed so the silhouette stays
    # readable at themed-icon sizes.
    llbl, lcount = ndimage.label(lightblue, structure=np.ones((3, 3)))
    lsizes = ndimage.sum(lightblue, llbl, range(1, lcount + 1))
    mono = gold.copy()
    for i in range(lcount):
        comp = i + 1
        if lsizes[i] < 2000:
            continue
        c = llbl == comp
        if (c & pin).sum() / max(1, c.sum()) < 0.99:
            continue
        mono |= c
    mlbl, mcount = ndimage.label(mono, structure=np.ones((3, 3)))
    msizes = ndimage.sum(mono, mlbl, range(1, mcount + 1))
    for i in range(mcount):
        if msizes[i] < 15:
            mono[mlbl == i + 1] = False
    mono = ndimage.binary_closing(mono, structure=np.ones((3, 3)), iterations=1)
    mono_rgba = np.dstack(
        [np.zeros((h, w, 3), dtype=np.uint8), (mono * 255).astype(np.uint8)]
    )
    monochrome = Image.fromarray(mono_rgba, "RGBA")

    return {
        "source": raw,
        "background": Image.fromarray(background.astype(np.uint8), "RGB"),
        "foreground": foreground,
        "legacy": legacy,
        "round": round_icon,
        "monochrome": monochrome,
    }


def build_adaptive_layers(
    masters: dict[str, Image.Image]
) -> tuple[Image.Image, Image.Image, Image.Image]:
    fg = masters["foreground"]
    mono = masters["monochrome"]
    a = np.asarray(fg.getchannel("A"))
    ys, xs = np.where(a > 12)
    cy = (ys.min() + ys.max()) / 2
    cx = (xs.min() + xs.max()) / 2
    radius = float(
        np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2).max()
    )
    scale = SAFE_RADIUS * SAFE_FILL / radius
    new_w = int(round(fg.width * scale))
    new_h = int(round(fg.height * scale))
    offset = (
        int(round(ADAPTIVE_CANVAS / 2 - cx * scale)),
        int(round(ADAPTIVE_CANVAS / 2 - cy * scale)),
    )

    def layer(image: Image.Image) -> Image.Image:
        scaled = image.resize((new_w, new_h), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (ADAPTIVE_CANVAS, ADAPTIVE_CANVAS), (0, 0, 0, 0))
        canvas.alpha_composite(scaled, offset)
        return canvas

    background = masters["background"].resize(
        (ADAPTIVE_CANVAS, ADAPTIVE_CANVAS), Image.Resampling.LANCZOS
    )
    return layer(fg), layer(mono), background


def write_android_resources(masters: dict[str, Image.Image]) -> None:
    foreground, monochrome, background = build_adaptive_layers(masters)
    legacy = masters["legacy"]
    round_icon = masters["round"]

    for folder, size in LEGACY_SIZES.items():
        _save_downsized(legacy, RES / folder / "ic_launcher.png", size)
        _save_downsized(round_icon, RES / folder / "ic_launcher_round.png", size)

    for folder, size in ADAPTIVE_SIZES.items():
        _save_downsized(
            foreground, RES / folder / "ic_launcher_foreground.png", size
        )
        _save_downsized(
            monochrome, RES / folder / "ic_launcher_monochrome.png", size
        )
        _save_downsized(
            background, RES / folder / "ic_launcher_background.png", size
        )

    adaptive = RES / "mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""
    (adaptive / "ic_launcher.xml").write_text(xml, encoding="utf-8")
    (adaptive / "ic_launcher_round.xml").write_text(xml, encoding="utf-8")


def write_previews(masters: dict[str, Image.Image]) -> None:
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    legacy = masters["legacy"]
    round_icon = masters["round"]
    monochrome = masters["monochrome"]
    foreground, mono_layer, background = build_adaptive_layers(masters)

    for size in (192, 96, 64, 48):
        legacy.resize((size, size), Image.Resampling.LANCZOS).save(
            PREVIEWS / f"legacy_{size}.png"
        )
        round_icon.resize((size, size), Image.Resampling.LANCZOS).save(
            PREVIEWS / f"round_{size}.png"
        )

    full = background.convert("RGBA")
    full.alpha_composite(foreground)
    full.resize((512, 512), Image.Resampling.LANCZOS).save(
        PREVIEWS / "adaptive_full_512.png"
    )

    for mask_name, mask in (
        ("circle", _circle_mask(512)),
        ("squircle", _squircle_mask(512)),
    ):
        masked = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
        prepared = full.resize((512, 512), Image.Resampling.LANCZOS)
        masked.paste(prepared, (0, 0), mask)
        radius = 512 * (72 / 108) / 2
        box = (
            int(512 / 2 - radius), int(512 / 2 - radius),
            int(512 / 2 + radius), int(512 / 2 + radius),
        )
        visible = masked.crop(box).resize((512, 512), Image.Resampling.LANCZOS)
        visible.save(PREVIEWS / f"adaptive_{mask_name}_preview_512.png")
        for tone, color in (
            ("light", (242, 244, 248, 255)),
            ("dark", (16, 24, 40, 255)),
        ):
            tile = Image.new("RGBA", (512, 512), color)
            tile.alpha_composite(visible)
            tile.convert("RGB").save(
                PREVIEWS / f"adaptive_{mask_name}_{tone}_512.png"
            )

    for size in (144, 96, 48):
        mono = monochrome.resize((size, size), Image.Resampling.LANCZOS)
        for tone, color, tint in (
            ("light", (242, 244, 248, 255), (16, 24, 40, 255)),
            ("dark", (16, 24, 40, 255), (255, 255, 255, 255)),
        ):
            tile = Image.new("RGBA", (size + 24, size + 24), color)
            tile.alpha_composite(_tint(mono, tint), (12, 12))
            tile.convert("RGB").save(
                PREVIEWS / f"monochrome_{size}_{tone}.png"
            )

    sheet = Image.new("RGB", (1220, 760), (242, 244, 248))
    draw = ImageDraw.Draw(sheet)
    draw.text((24, 20), "Branding 1.0 - launcher icon previews", fill=(16, 24, 40))
    x = 24
    for size in (192, 96, 64, 48):
        icon = legacy.resize((size, size), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (192, 192), (255, 255, 255, 255))
        tile.alpha_composite(icon, ((192 - size) // 2, (192 - size) // 2))
        sheet.paste(tile.convert("RGB"), (x, 56))
        x += 192 + 16
    for i, name in enumerate(
        ("adaptive_circle_light_512", "adaptive_squircle_light_512")
    ):
        source = Image.open(PREVIEWS / f"{name}.png").resize(
            (320, 320), Image.Resampling.LANCZOS
        )
        sheet.paste(source, (24 + i * 344, 272))
    for i, name in enumerate(("monochrome_96_light", "monochrome_96_dark")):
        source = Image.open(PREVIEWS / f"{name}.png").resize(
            (192, 192), Image.Resampling.LANCZOS
        )
        sheet.paste(source, (24 + i * 216, 616))
    sheet.save(PREVIEWS / "branding_icons_sheet.png")


def write_metadata() -> None:
    digest = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    size = Image.open(SOURCE).size
    metadata = {
        "name": "Петербург в деталях",
        "source": "docs/branding/original_app_icon.png",
        "format": "PNG",
        "size": f"{size[0]}x{size[1]}",
        "sha256": digest,
        "note": (
            "Source provided by the project creator; optimized Android layers "
            "are generated separately by tool/generate_branding_icons.py."
        ),
    }
    (REPO / "docs" / "branding" / "icon_metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    masters = build_masters()
    write_android_resources(masters)
    write_previews(masters)
    write_metadata()
    print(f"Android icons written to {RES}")
    print(f"Previews written to {PREVIEWS}")


if __name__ == "__main__":
    main()
