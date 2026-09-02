#!/usr/bin/env python3
"""macOS Dock mockup with the Dynamic Island icon at hover size."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
PREVIEW = ROOT / "preview"
SOURCE = PREVIEW / "dock-source"
OUR_ICON = ROOT / "macos" / "AppIcon-1024.png"

W, H = 1800, 1120
ICON = 92
ICON_HOVER = 128
GAP = 14
PAD_X = 22
PAD_Y = 16
DOCK_H = PAD_Y * 2 + ICON + 18  # room for indicator


def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/SFNSText.ttf",
        "/System/Library/Fonts/SFProText-Regular.otf",
        "/System/Library/Fonts/Supplemental/SFProText-Semibold.otf" if bold else "/System/Library/Fonts/Supplemental/SFProText-Regular.otf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in candidates:
        try:
            return ImageFont.truetype(p, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def rounded_rect_mask(w: int, h: int, r: int) -> Image.Image:
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    return m


def wallpaper() -> Image.Image:
    """Dark macOS-style desktop with a soft purple bloom behind the dock."""
    y, x = np.ogrid[:H, :W]
    t = y / max(H - 1, 1)
    top = np.array([18.0, 16.0, 28.0])
    bot = np.array([6.0, 6.0, 10.0])
    rgb = (1.0 - t)[..., None] * top + t[..., None] * bot
    # faint radial bloom near dock
    cx, cy = W * 0.5, H * 0.78
    rr = np.sqrt(((x - cx) / (W * 0.42)) ** 2 + ((y - cy) / (H * 0.38)) ** 2)
    bloom = np.clip(1.0 - rr, 0.0, 1.0) ** 1.8
    rgb = rgb + bloom[..., None] * np.array([42.0, 18.0, 68.0])
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    return img


def glass_dock(width: int, height: int) -> Image.Image:
    """Liquid-glass stadium plate."""
    r = height // 2
    mask = rounded_rect_mask(width, height, r)
    plate = Image.new("RGBA", (width, height), (32, 32, 36, 168))
    base = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    base.paste(plate, (0, 0), mask)
    arr = np.array(base).astype(np.float64)
    yy = np.linspace(0, 1, height)[:, None]
    shine = np.clip(1.0 - yy * 1.8, 0, 1) * 42
    arr[..., 0] += shine
    arr[..., 1] += shine
    arr[..., 2] += shine
    arr[..., 3] = np.array(mask).astype(np.float64) * (168 / 255.0) + shine * 0.35
    stroke = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(stroke).rounded_rectangle(
        (0.5, 0.5, width - 1.5, height - 1.5), radius=r, outline=(255, 255, 255, 55), width=1
    )
    out = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return Image.alpha_composite(out, stroke)


def load_icon(path: Path, size: int) -> Image.Image:
    im = Image.open(path).convert("RGBA")
    im = im.resize((size, size), Image.Resampling.LANCZOS)
    return im


def drop_shadow(icon: Image.Image, blur: int = 10, dy: int = 6, alpha: int = 90) -> Image.Image:
    w, h = icon.size
    canvas = Image.new("RGBA", (w + blur * 4, h + blur * 4 + dy), (0, 0, 0, 0))
    shadow = Image.new("RGBA", icon.size, (0, 0, 0, alpha))
    shadow.putalpha(icon.split()[-1].point(lambda p: min(255, int(p * alpha / 255))))
    canvas.paste(shadow, (blur * 2, blur * 2 + dy), shadow)
    canvas = canvas.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(icon, (blur * 2, blur * 2))
    return canvas


def tooltip(text: str) -> Image.Image:
    f = font(15)
    dummy = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    bbox = dummy.textbbox((0, 0), text, font=f)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad_x, pad_y = 12, 6
    w, h = tw + pad_x * 2, th + pad_y * 2
    img = Image.new("RGBA", (w, h + 6), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius=h // 2, fill=(40, 40, 44, 220))
    d.text((pad_x, pad_y - 1), text, font=f, fill=(245, 245, 247, 255))
    # caret
    cx = w // 2
    d.polygon([(cx - 5, h - 1), (cx + 5, h - 1), (cx, h + 5)], fill=(40, 40, 44, 220))
    return img


def separator(h: int) -> Image.Image:
    img = Image.new("RGBA", (2, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 8, 1, h - 8), radius=1, fill=(255, 255, 255, 48))
    return img


def main() -> None:
    items: list[tuple[str, Path | None, bool]] = [
        ("Finder", SOURCE / "finder.png", True),
        ("Safari", SOURCE / "safari.png", False),
        ("Messages", SOURCE / "messages.png", False),
        ("Mail", SOURCE / "mail.png", False),
        ("Photos", SOURCE / "photos.png", False),
        ("Music", SOURCE / "music.png", False),
        ("Dynamic Island", OUR_ICON, True),  # hover + running
        ("Notes", SOURCE / "notes.png", False),
        ("Calendar", SOURCE / "calendar.png", False),
        ("Cursor", SOURCE / "cursor.png", True),
        ("System Settings", SOURCE / "settings.png", False),
        ("__sep__", None, False),
        ("Trash", SOURCE / "trash.png", False),
    ]

    # Measure dock width with hover icon occupying extra space
    widths = []
    for name, _, hover in items:
        if name == "__sep__":
            widths.append(10)
        else:
            widths.append(ICON_HOVER if name == "Dynamic Island" else ICON)
    content_w = sum(widths) + GAP * (len(widths) - 1)
    dock_w = content_w + PAD_X * 2
    dock_h = PAD_Y * 2 + ICON_HOVER + 10

    desk = wallpaper().convert("RGBA")
    # menu bar
    bar = Image.new("RGBA", (W, 32), (18, 18, 22, 140))
    desk.alpha_composite(bar, (0, 0))
    d = ImageDraw.Draw(desk)
    d.text((18, 7), "Dynamic Island", font=font(13), fill=(236, 236, 240, 230))
    # clock
    clock = "Tue  6:10"
    cw = d.textlength(clock, font=font(13))
    d.text((W - 18 - cw, 7), clock, font=font(13), fill=(236, 236, 240, 230))

    # dock plate
    plate = glass_dock(dock_w, dock_h)
    # frost: blur wallpaper region
    dx = (W - dock_w) // 2
    dy = H - dock_h - 28
    region = desk.crop((dx, dy, dx + dock_w, dy + dock_h)).filter(ImageFilter.GaussianBlur(22))
    frost = Image.new("RGBA", (dock_w, dock_h), (255, 255, 255, 0))
    frost.paste(region, (0, 0))
    frost.putalpha(rounded_rect_mask(dock_w, dock_h, dock_h // 2).point(lambda p: int(p * 0.55)))
    dock_layer = Image.new("RGBA", (dock_w, dock_h), (0, 0, 0, 0))
    dock_layer = Image.alpha_composite(dock_layer, frost)
    dock_layer = Image.alpha_composite(dock_layer, plate)
    # drop shadow under dock
    shadow = Image.new("RGBA", (dock_w + 80, dock_h + 50), (0, 0, 0, 0))
    sh = Image.new("RGBA", (dock_w, dock_h), (0, 0, 0, 110))
    sh.putalpha(rounded_rect_mask(dock_w, dock_h, dock_h // 2).point(lambda p: int(p * 0.45)))
    shadow.paste(sh, (40, 18), sh)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    desk.alpha_composite(shadow, (dx - 40, dy - 4))
    desk.alpha_composite(dock_layer, (dx, dy))

    # icons
    x = dx + PAD_X
    baseline = dy + PAD_Y + (ICON_HOVER - ICON)  # smaller icons sit on a shared baseline
    hover_center_x = None
    for name, path, running in items:
        if name == "__sep__":
            sep = separator(ICON - 8)
            desk.alpha_composite(sep, (x, baseline + 8))
            x += 10 + GAP
            continue
        size = ICON_HOVER if name == "Dynamic Island" else ICON
        icon = load_icon(path, size)
        y = dy + PAD_Y + (ICON_HOVER - size)
        shadowed = drop_shadow(icon, blur=8 if name != "Dynamic Island" else 12, dy=5, alpha=80 if name != "Dynamic Island" else 110)
        # drop_shadow expands canvas
        ox = x - (shadowed.size[0] - size) // 2
        oy = y - (shadowed.size[1] - size) // 2 + 4
        desk.alpha_composite(shadowed, (ox, oy))
        if running:
            # indicator dot
            dot_x = int(x + size / 2)
            dot_y = dy + dock_h - 11
            dd = ImageDraw.Draw(desk)
            dd.ellipse((dot_x - 3, dot_y - 3, dot_x + 3, dot_y + 3), fill=(230, 230, 235, 230))
        if name == "Dynamic Island":
            hover_center_x = x + size / 2
            hover_top = y
        x += size + GAP

    tip = tooltip("Dynamic Island")
    tx = int(hover_center_x - tip.size[0] / 2)
    ty = int(hover_top - tip.size[1] - 10)
    desk.alpha_composite(tip, (tx, ty))

    out = desk.convert("RGB")
    dest = PREVIEW / "dock.png"
    dest.parent.mkdir(parents=True, exist_ok=True)
    out.save(dest, format="PNG", optimize=True)
    close = out.crop((0, H - 420, W, H))
    close.save(PREVIEW / "dock-closeup.png", format="PNG", optimize=True)
    print("Wrote", dest)


if __name__ == "__main__":
    main()
