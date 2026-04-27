"""Final two icons: light + dark variants of cat-cube buddy."""
from PIL import Image, ImageDraw
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_v2 import (
    new_canvas, finalize, draw_cat_cube, GRID, INK,
)

OUT = os.path.dirname(os.path.abspath(__file__))

# ---- LIGHT (v5 clean_excited) ----
LIGHT = {
    "bg": (250, 244, 235, 255), "bg_dot": (235, 224, 210, 255),
    "body": (160, 210, 255, 255), "body_d": (90, 150, 230, 255),
    "screen_frame": INK, "screen_bg": (245, 244, 252, 255),
    "face": (40, 36, 60, 255),
    "accent_a": (255, 168, 188, 255),
    "accent_b": (140, 230, 200, 255),
    "accent_c": (255, 200, 100, 255),
    "ear_inner": (255, 168, 188, 255),
    "nose": (255, 130, 160, 255),
    "ink": INK,
    "tail": (160, 210, 255, 255),
}

# ---- DARK (v3 pink_sleepy with much darker bg) ----
# Body stays pink so it still reads as "cute buddy" against the dark.
# Background is near-black navy with very subtle stripes.
DARK = {
    "bg": (14, 16, 28, 255), "bg_dot": (28, 32, 52, 255),
    "body": (255, 180, 200, 255), "body_d": (220, 120, 160, 255),
    "screen_frame": (8, 10, 18, 255), "screen_bg": (50, 30, 60, 255),
    "face": (255, 230, 140, 255),
    "accent_a": (255, 230, 140, 255),
    "accent_b": (200, 180, 255, 255),
    "accent_c": (140, 220, 255, 255),
    "ear_inner": (255, 220, 230, 255),
    "nose": (220, 120, 160, 255),
    "ink": (8, 10, 18, 255),
    "tail": (255, 180, 200, 255),
}

def make(name, theme, face, bg_pattern):
    img, px = new_canvas(theme["bg"])
    draw_cat_cube(px, theme, face=face, bg_pattern=bg_pattern)
    finalize(img, name)

make("final_light", LIGHT, "excited", "none")
make("final_dark",  DARK,  "sleepy",  "stripes")

# side-by-side preview
thumb = 512
pad = 32
W = 2 * thumb + 3 * pad
H = thumb + 2 * pad + 60
sheet = Image.new("RGBA", (W, H), (235, 232, 226, 255))
draw = ImageDraw.Draw(sheet)
for i, n in enumerate(["final_light", "final_dark"]):
    im = Image.open(os.path.join(OUT, f"{n}.png")).resize((thumb, thumb), Image.NEAREST)
    sheet.paste(im, (pad + i * (thumb + pad), pad), im)
    draw.text((pad + i * (thumb + pad) + 12, pad + thumb + 12), n, fill=(40,36,60,255))
sheet.save(os.path.join(OUT, "00_final_pair.png"))
print("done")
