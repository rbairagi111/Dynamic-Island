#!/usr/bin/env python3
"""Render Dynamic Island app icons to Apple HIG (iOS 26 / macOS 26).

Square 1024 masters have no baked mask. Squircle is applied only on
preview/macOS Dock assets. Appearances: default, dark, tinted (mono).
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
SUPERSAMPLE = 2
GRID = SIZE  # Apple 1024 pt canvas
# Wide glyph keyline: 640×192 sits on 64 px grid, ~3.33:1 like the hardware island.
PILL_W = 640
PILL_H = 192

ROOT = Path(__file__).resolve().parent
LAYERS = ROOT / "layers"
PREVIEW = ROOT / "preview"
IOS = ROOT / "ios"
MAC = ROOT / "macos"


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1.0 / 2.4) - 0.055)


def hex_rgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i : i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float64)


def smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def sd_stadium(x: np.ndarray, y: np.ndarray, cx: float, cy: float, width: float, height: float) -> np.ndarray:
    radius = height * 0.5
    half_span = width * 0.5 - radius
    dx = np.abs(x - cx) - half_span
    dx = np.where(dx < 0.0, 0.0, dx)
    dy = y - cy
    return np.sqrt(dx * dx + dy * dy) - radius


def superellipse_mask(n: int, power: float = 5.2) -> np.ndarray:
    """iOS-like squircle coverage, 1 inside."""
    yy, xx = np.ogrid[-1 : 1 : n * 1j, -1 : 1 : n * 1j]
    v = np.abs(xx) ** power + np.abs(yy) ** power
    # Anti-alias ~1 px at destination size
    px = 2.0 / n
    return np.clip((1.0 - v) / (px * power * 1.15) + 0.5, 0.0, 1.0)


def coords(n: int):
    y, x = np.meshgrid(np.arange(n, dtype=np.float64), np.arange(n, dtype=np.float64), indexing="ij")
    return x, y


def gaussian_blur_channel(ch: np.ndarray, radius: float) -> np.ndarray:
    if radius <= 0.05:
        return ch
    img = Image.fromarray(np.clip(ch * 255.0, 0, 255).astype(np.uint8))
    img = img.filter(ImageFilter.GaussianBlur(radius=radius))
    return np.asarray(img, dtype=np.float64) / 255.0


def composite(dst: np.ndarray, src: np.ndarray, a: np.ndarray) -> None:
    a = a[..., None] if a.ndim == 2 else a
    dst *= 1.0 - a
    dst += src * a


def render_appearance(kind: str, n: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return (flat_rgb, background_rgb, glyph_rgba) in linear light, 0..1."""
    x, y = coords(n)
    scale = n / GRID
    cx, cy = n * 0.5, n * 0.5
    # Optical lift: a hair above true center reads more balanced under top lighting.
    cy -= 6.0 * scale
    pw, ph = PILL_W * scale, PILL_H * scale
    d = sd_stadium(x, y, cx, cy, pw, ph)

    gy, gx = np.gradient(d)
    mag = np.sqrt(gx * gx + gy * gy) + 1e-6
    nx, ny = gx / mag, gy / mag

    # Light from above, slightly in front — matches Icon Composer’s vertical light.
    lx, ly, lz = 0.18, -0.92, 0.78
    ln = math.sqrt(lx * lx + ly * ly + lz * lz)
    lx, ly, lz = lx / ln, ly / ln, lz / ln
    ndotl = np.clip(nx * lx + ny * ly, 0.0, 1.0)

    aa = 1.15 * scale
    inside = smoothstep(aa, -aa, d)
    edge = np.exp(-0.5 * (d / (1.35 * scale)) ** 2)

    if kind == "default":
        # Source mark: black field, [24,10,35] void, rim ~[193,156,217], violet bloom.
        glow_rgb = hex_rgb("C9A0E8")
        glow2_rgb = hex_rgb("7A3BB8")
        bg_top = hex_rgb("140C1C")
        bg_bot = hex_rgb("030206")
        bg_mid = hex_rgb("0A0612")
        pill_core = hex_rgb("0C0614")
        pill_lift = hex_rgb("181022")
        rim_col = hex_rgb("C19CD9")
        spec_col = hex_rgb("F3E8FF")
        glow_gain, glow_sigma = 1.18 * 0.60 * 1.20, 86.0 * 1.10 * 1.20 * scale
        plate = 0.055
    elif kind == "dark":
        glow_rgb = hex_rgb("A78BFA")
        glow2_rgb = hex_rgb("4C1D95")
        bg_top = hex_rgb("0C0812")
        bg_bot = hex_rgb("010102")
        bg_mid = hex_rgb("06040A")
        pill_core = hex_rgb("07040C")
        pill_lift = hex_rgb("120A1A")
        rim_col = hex_rgb("C4B5FD")
        spec_col = hex_rgb("EDE9FE")
        glow_gain, glow_sigma = 0.72 * 0.60 * 1.20, 74.0 * 1.10 * 1.20 * scale
        plate = 0.03
    else:  # tinted / mono — white glyph, no chroma, high contrast
        glow_rgb = hex_rgb("FFFFFF")
        glow2_rgb = hex_rgb("D4D4D8")
        bg_top = hex_rgb("3A3A3C")
        bg_bot = hex_rgb("1C1C1E")
        bg_mid = hex_rgb("2C2C2E")
        pill_core = hex_rgb("F5F5F7")
        pill_lift = hex_rgb("FFFFFF")
        rim_col = hex_rgb("FFFFFF")
        spec_col = hex_rgb("FFFFFF")
        glow_gain, glow_sigma = 0.0, 40.0 * scale
        plate = 0.08

    # --- Background plate (full-bleed; system will mask) ---
    t = y / max(n - 1, 1)
    # Soft S-curve vertical: lighter glass at the top, denser at the bottom.
    vg = smoothstep(0.0, 1.0, t)
    bg = (1.0 - vg)[..., None] * srgb_to_linear(bg_top) + vg[..., None] * srgb_to_linear(bg_bot)
    # Radial richness behind the island
    rr = np.sqrt(((x - cx) / (n * 0.42)) ** 2 + ((y - cy) / (n * 0.38)) ** 2)
    radial = np.clip(1.0 - rr, 0.0, 1.0) ** 1.35
    bg = bg * (1.0 - 0.35 * radial[..., None]) + srgb_to_linear(bg_mid) * (0.35 * radial[..., None])

    # Top plate light (Liquid Glass icon catching UI light from above)
    plate_falloff = np.clip(1.0 - (y / (n * 0.55)), 0.0, 1.0) ** 1.6
    bg = bg + plate_falloff[..., None] * plate * srgb_to_linear(np.array([0.92, 0.88, 1.0]))

    # Bloom — outside the pill, tight enough that the squircle mask won’t clip a halo
    if glow_gain > 0:
        outside = np.maximum(d, 0.0)
        bloom = np.exp(-0.5 * (outside / glow_sigma) ** 2) * glow_gain
        bloom *= 1.0 - inside * 0.92
        bloom2 = np.exp(-0.5 * (outside / (glow_sigma * 0.42)) ** 2) * glow_gain * 1.15
        bloom2 *= 1.0 - inside
        # Soften
        bloom_s = gaussian_blur_channel(bloom, 7.0 * 1.10 * 1.20 * scale)
        bloom2_s = gaussian_blur_channel(bloom2, 2.2 * 1.10 * 1.20 * scale)
        bg = bg + bloom_s[..., None] * srgb_to_linear(glow2_rgb) * 0.85
        bg = bg + bloom2_s[..., None] * srgb_to_linear(glow_rgb) * 0.95

    bg = np.clip(bg, 0.0, 1.0)

    # --- Glyph: glass Dynamic Island capsule ---
    # Height shading inside the pill
    local_y = (y - (cy - ph * 0.5)) / max(ph, 1.0)
    body = (1.0 - local_y)[..., None] * srgb_to_linear(pill_lift) + local_y[..., None] * srgb_to_linear(pill_core)

    if kind == "tinted":
        # Solid light silhouette that survives system tinting / clear modes
        body = np.broadcast_to(srgb_to_linear(pill_core), body.shape).copy()
        top_band = smoothstep(cy - ph * 0.12, cy - ph * 0.42, y)
        body = body * 0.88 + srgb_to_linear(pill_lift) * (0.12 * top_band[..., None])
        rim = edge * inside * 0.35
        inner_ao = smoothstep(-ph * 0.02, -ph * 0.28, -d) * 0.08
        body = body * (1.0 - inner_ao)[..., None]
        glyph_rgb = np.clip(body + rim[..., None] * 0.25, 0.0, 1.0)
        glyph_a = inside
    else:
        # Hardware island: dark void, thin glass rim, light from above on the lip only.
        # Do not shade it as a chrome cylinder — that fights both the source mark and HIG simplicity.
        void = smoothstep(-1.6 * scale, -ph * 0.22, -d)
        body = body * (1.0 - 0.72 * void)[..., None]
        rim = np.exp(-0.5 * (d / (1.05 * scale)) ** 2)
        top_lip = rim * smoothstep(cy - ph * 0.08, cy - ph * 0.48, y)
        # Keep ndotl only as a whisper on the rim, never across the fill.
        spec = top_lip * (0.78 + 0.22 * ndotl)
        spec = gaussian_blur_channel(spec, 0.55 * scale)
        body = body + inside[..., None] * srgb_to_linear(glow_rgb) * 0.035
        glass = body
        glass = glass + rim[..., None] * srgb_to_linear(rim_col) * 0.82
        glass = glass + spec[..., None] * srgb_to_linear(spec_col) * 0.55
        glyph_rgb = np.clip(glass, 0.0, 1.0)
        glyph_a = np.clip(inside + rim * 0.22, 0.0, 1.0)

    # Flatten
    flat = bg.copy()
    composite(flat, glyph_rgb, glyph_a)
    flat = np.clip(flat, 0.0, 1.0)

    glyph_rgba = np.dstack([glyph_rgb, glyph_a])
    return flat, bg, glyph_rgba


def to_u8_rgb(lin: np.ndarray) -> Image.Image:
    srgb = linear_to_srgb(lin)
    arr = np.clip(np.round(srgb * 255.0), 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def to_u8_rgba(lin_rgba: np.ndarray) -> Image.Image:
    rgb = linear_to_srgb(lin_rgba[..., :3])
    a = np.clip(lin_rgba[..., 3], 0.0, 1.0)
    arr = np.clip(np.round(np.concatenate([rgb, a[..., None]], axis=-1) * 255.0), 0, 255).astype(np.uint8)
    return Image.fromarray(arr)


def downscale(img: Image.Image, size: int) -> Image.Image:
    if img.size == (size, size):
        return img
    return img.resize((size, size), Image.Resampling.LANCZOS)


def apply_squircle(rgb: Image.Image) -> Image.Image:
    n = rgb.size[0]
    mask = (superellipse_mask(n) * 255.0).astype(np.uint8)
    rgba = rgb.convert("RGBA")
    rgba.putalpha(Image.fromarray(mask))
    return rgba


def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, format="PNG", optimize=True)


def try_font(size: int) -> ImageFont.ImageFont:
    for p in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSText.ttf",
        "/System/Library/Fonts/Supplemental/SFProText-Regular.otf",
        "/System/Library/Fonts/SFProText.ttf",
        "/Library/Fonts/SF-Pro-Text-Regular.otf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        try:
            return ImageFont.truetype(p, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def appearance_sheet(squircles: dict[str, Image.Image]) -> Image.Image:
    """Home Screen–style review: three squircles + small-size row."""
    W, H = 1600, 980
    bg = Image.new("RGB", (W, H), (12, 12, 14))
    # Soft vignette
    arr = np.zeros((H, W, 3), dtype=np.float64)
    yy, xx = np.ogrid[:H, :W]
    r = np.sqrt(((xx - W / 2) / (W * 0.55)) ** 2 + ((yy - H / 2) / (H * 0.6)) ** 2)
    vignette = np.clip(1.0 - r * 0.35, 0.55, 1.0)
    arr[:] = np.array([18.0, 16.0, 24.0]) * vignette[..., None]
    bg = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(bg)
    title_font = try_font(36)
    label_font = try_font(22)
    small_font = try_font(16)
    draw.text((80, 56), "Dynamic Island", font=title_font, fill=(245, 245, 247))
    draw.text((80, 104), "iOS 26 appearances  ·  1024×1024  ·  system-masked squircle", font=small_font, fill=(174, 174, 178))

    order = [("default", "Default"), ("dark", "Dark"), ("tinted", "Tinted")]
    icon_n = 360
    gap = 80
    total = 3 * icon_n + 2 * gap
    x0 = (W - total) // 2
    y0 = 190
    for i, (key, label) in enumerate(order):
        icon = squircles[key].resize((icon_n, icon_n), Image.Resampling.LANCZOS)
        x = x0 + i * (icon_n + gap)
        bg.paste(icon, (x, y0), icon)
        tw = draw.textlength(label, font=label_font)
        draw.text((x + (icon_n - tw) / 2, y0 + icon_n + 22), label, font=label_font, fill=(242, 242, 247))

    # Small-size row from default
    draw.text((80, 680), "Scale check  ·  same silhouette at 76, 60, 40, 29, 20 pt", font=small_font, fill=(174, 174, 178))
    sizes = [76 * 3, 60 * 3, 40 * 3, 29 * 3, 20 * 3]  # @3x px
    labels = ["76pt", "60pt", "40pt", "29pt", "20pt"]
    xd = 80
    src = squircles["default"]
    for s, lab in zip(sizes, labels):
        im = src.resize((s, s), Image.Resampling.LANCZOS)
        bg.paste(im, (xd, 730), im)
        tw = draw.textlength(lab, font=small_font)
        draw.text((xd + (s - tw) / 2, 730 + s + 10), lab, font=small_font, fill=(142, 142, 147))
        xd += s + 36
    return bg


def write_icon_composer_svgs() -> None:
    """Flat SVG layers for Icon Composer (WWDC25+). System adds Liquid Glass."""
    out = LAYERS
    out.mkdir(parents=True, exist_ok=True)
    cx, cy = GRID / 2, GRID / 2 - 6
    x = cx - PILL_W / 2
    y = cy - PILL_H / 2
    r = PILL_H / 2
    stadium = (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{PILL_W}" height="{PILL_H}" '
        f'rx="{r}" ry="{r}"/>'
    )
    glyph = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <g id="Island">
    {stadium[:-2]} fill="#0C0614"/>
  </g>
</svg>
'''
    glyph_mono = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <g id="Island">
    {stadium[:-2]} fill="#F5F5F7"/>
  </g>
</svg>
'''
    background = '''<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="plate" x1="512" y1="0" x2="512" y2="1024" gradientUnits="userSpaceOnUse">
      <stop stop-color="#140C1C"/>
      <stop offset="1" stop-color="#030206"/>
    </linearGradient>
    <radialGradient id="bloom" cx="50%" cy="48%" r="50.16%">
      <stop stop-color="#7A3BB8" stop-opacity="0.648"/>
      <stop offset="0.45" stop-color="#7A3BB8" stop-opacity="0.252"/>
      <stop offset="1" stop-color="#030206" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#plate)"/>
  <rect width="1024" height="1024" fill="url(#bloom)"/>
</svg>
'''
    (out / "glyph.svg").write_text(glyph)
    (out / "glyph-mono.svg").write_text(glyph_mono)
    (out / "background.svg").write_text(background)


def main() -> None:
    for d in (LAYERS, PREVIEW, IOS, MAC):
        d.mkdir(parents=True, exist_ok=True)

    n = SIZE * SUPERSAMPLE
    flats: dict[str, Image.Image] = {}
    squircles: dict[str, Image.Image] = {}

    for kind in ("default", "dark", "tinted"):
        flat, bg, glyph = render_appearance(kind, n)
        flat_img = downscale(to_u8_rgb(flat), SIZE)
        bg_img = downscale(to_u8_rgb(bg), SIZE)
        glyph_img = downscale(to_u8_rgba(glyph), SIZE)
        flats[kind] = flat_img
        squircles[kind] = apply_squircle(flat_img)

        stem = "AppIcon-1024" if kind == "default" else f"AppIcon-1024-{kind}"
        save_png(flat_img, IOS / f"{stem}.png")
        save_png(squircles[kind], PREVIEW / f"{stem}-squircle.png")
        save_png(bg_img, LAYERS / f"{kind}-background.png")
        save_png(glyph_img, LAYERS / f"{kind}-glyph.png")

    sheet = appearance_sheet(squircles)
    save_png(sheet, PREVIEW / "appearances.png")
    write_icon_composer_svgs()

    # macOS Dock: squircle with transparency (pre–Icon Composer catalog)
    mac_sizes = (16, 32, 64, 128, 256, 512, 1024)
    mac_src = squircles["default"]
    for s in mac_sizes:
        save_png(mac_src.resize((s, s), Image.Resampling.LANCZOS), MAC / f"AppIcon-{s}.png")

    # Convenience copies at Design/AppIcon root
    save_png(flats["default"], ROOT / "AppIcon-1024.png")
    save_png(flats["dark"], ROOT / "AppIcon-1024-dark.png")
    save_png(flats["tinted"], ROOT / "AppIcon-1024-tinted.png")
    print("Wrote", ROOT)


if __name__ == "__main__":
    main()
