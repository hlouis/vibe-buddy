"""Build full AppIcon asset catalogs for iOS and macOS targets.

Inputs:
  docs/icon-drafts/final_light_square.png   (1024x1024, full bleed)
  docs/icon-drafts/final_dark_square.png    (1024x1024, full bleed)

Outputs:
  ios-app/VibeBuddy/Assets.xcassets/
    Contents.json
    AppIcon.appiconset/
      Contents.json
      icon_1024_light.png
      icon_1024_dark.png
      icon_1024_tinted.png  (grayscale of light, used as system tint base)
  macos-app/VibeBuddy/Assets.xcassets/
    Contents.json
    AppIcon.appiconset/
      Contents.json
      icon_<size>_light.png  for 16,32,64,128,256,512,1024 @1x and @2x
      icon_<size>_dark.png   same sizes

Modern Xcode (iOS 17+/macOS 14+) accepts a single 1024 image per appearance
for iOS via "platform: ios, idiom: universal, appearances: [luminosity]".
For macOS we still emit the classic mac iconset sizes, both light and dark.
"""
from PIL import Image
import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_LIGHT = os.path.join(ROOT, "docs/icon-drafts/final_light_square.png")
SRC_DARK = os.path.join(ROOT, "docs/icon-drafts/final_dark_square.png")

IOS_ASSETS = os.path.join(ROOT, "ios-app/VibeBuddy/Assets.xcassets")
MAC_ASSETS = os.path.join(ROOT, "macos-app/VibeBuddy/Assets.xcassets")


def load(p):
    return Image.open(p).convert("RGBA")


def resize(img, size):
    return img.resize((size, size), Image.NEAREST)


def to_tinted(img):
    # Convert to grayscale-with-alpha so the system tinting can colorize.
    # Apple expects mostly white-on-transparent for tinted iOS icons; we'll
    # produce a light grayscale on transparent background (drop the bg).
    # For pixel art we just use the body silhouette — keep alpha shape, fill white-ish gray by luminance.
    rgba = img.copy()
    px = rgba.load()
    w, h = rgba.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            lum = int(0.299 * r + 0.587 * g + 0.114 * b)
            # remap so darkest -> 40, brightest -> 255
            v = max(40, min(255, lum))
            px[x, y] = (v, v, v, 255)
    return rgba


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def ensure_clean_dir(path):
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(path)


# ---------------- iOS ----------------

def build_ios():
    light = load(SRC_LIGHT)
    dark = load(SRC_DARK)
    if light.size != (1024, 1024):
        light = light.resize((1024, 1024), Image.NEAREST)
    if dark.size != (1024, 1024):
        dark = dark.resize((1024, 1024), Image.NEAREST)
    tinted = to_tinted(light)

    ensure_clean_dir(IOS_ASSETS)
    write_json(os.path.join(IOS_ASSETS, "Contents.json"), {
        "info": {"author": "xcode", "version": 1}
    })

    iconset = os.path.join(IOS_ASSETS, "AppIcon.appiconset")
    os.makedirs(iconset)
    light.save(os.path.join(iconset, "icon_1024_light.png"))
    dark.save(os.path.join(iconset, "icon_1024_dark.png"))
    tinted.save(os.path.join(iconset, "icon_1024_tinted.png"))

    # iOS 18+ single-size AppIcon with appearance variants.
    contents = {
        "images": [
            {
                "filename": "icon_1024_light.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [
                    {"appearance": "luminosity", "value": "dark"}
                ],
                "filename": "icon_1024_dark.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
            {
                "appearances": [
                    {"appearance": "luminosity", "value": "tinted"}
                ],
                "filename": "icon_1024_tinted.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            },
        ],
        "info": {"author": "xcode", "version": 1},
    }
    write_json(os.path.join(iconset, "Contents.json"), contents)
    print(f"[iOS] wrote {iconset}")


# ---------------- macOS ----------------

# (size_pt, scale) tuples per Apple iconset spec
MAC_SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def build_mac():
    light = load(SRC_LIGHT)
    dark = load(SRC_DARK)
    if light.size != (1024, 1024):
        light = light.resize((1024, 1024), Image.NEAREST)
    if dark.size != (1024, 1024):
        dark = dark.resize((1024, 1024), Image.NEAREST)

    ensure_clean_dir(MAC_ASSETS)
    write_json(os.path.join(MAC_ASSETS, "Contents.json"), {
        "info": {"author": "xcode", "version": 1}
    })

    iconset = os.path.join(MAC_ASSETS, "AppIcon.appiconset")
    os.makedirs(iconset)

    images = []
    for size, scale in MAC_SIZES:
        px_size = size * scale
        light_name = f"icon_{size}x{size}@{scale}x_light.png"
        dark_name = f"icon_{size}x{size}@{scale}x_dark.png"
        resize(light, px_size).save(os.path.join(iconset, light_name))
        resize(dark, px_size).save(os.path.join(iconset, dark_name))
        images.append({
            "filename": light_name,
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size}x{size}",
        })
        images.append({
            "appearances": [
                {"appearance": "luminosity", "value": "dark"}
            ],
            "filename": dark_name,
            "idiom": "mac",
            "scale": f"{scale}x",
            "size": f"{size}x{size}",
        })

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    write_json(os.path.join(iconset, "Contents.json"), contents)
    print(f"[mac] wrote {iconset}")


if __name__ == "__main__":
    build_ios()
    build_mac()
