"""Variants of the cat-cube buddy (design 05).

Five variants — different palette / face / pose — for picking a final.
"""
from PIL import Image, ImageDraw
import os

OUT = os.path.dirname(os.path.abspath(__file__))
GRID = 32
SCALE = 32
SIZE = GRID * SCALE
RADIUS = 224

def new_canvas(bg):
    img = Image.new("RGBA", (GRID, GRID), bg)
    return img, img.load()

def fill(px, x, y, c):
    if 0 <= x < GRID and 0 <= y < GRID:
        px[x, y] = c

def rect(px, x0, y0, x1, y1, c):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            fill(px, x, y, c)

def finalize(img, name):
    big = img.resize((SIZE, SIZE), Image.NEAREST)
    mask = Image.new("L", (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, SIZE, SIZE), radius=RADIUS, fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(big, (0, 0), mask)
    out.save(os.path.join(OUT, f"{name}.png"))
    big.save(os.path.join(OUT, f"{name}_square.png"))


def darken(c, k=20):
    r,g,b,a = c
    return (max(0,r-k), max(0,g-k), max(0,b-k), a)


def draw_cat_cube(px, theme, face="happy", pose="center", bg_pattern="dots"):
    """
    theme keys:
      bg, bg_dot, body, body_d, screen_frame, screen_bg, scan,
      face, accent_a, accent_b, accent_c, ear_inner, nose, ink, tail
    face: happy | wink | sleepy | smug | excited
    pose: center | tilt_left | peek_right
    bg_pattern: dots | stripes | none | sparkle
    """
    T = theme

    # Background pattern
    if bg_pattern == "dots":
        for y in range(GRID):
            for x in range(GRID):
                if (x*7 + y*3) % 11 == 0:
                    fill(px, x, y, T["bg_dot"])
    elif bg_pattern == "stripes":
        for y in range(GRID):
            for x in range(GRID):
                if (x + y) % 5 == 0:
                    fill(px, x, y, T["bg_dot"])
    elif bg_pattern == "sparkle":
        for x,y in [(4,5),(27,7),(6,26),(25,24),(3,15),(28,16),(10,3),(22,28),(15,29)]:
            fill(px, x, y, T["bg_dot"])
            fill(px, x+1, y, T["bg_dot"])
            fill(px, x, y+1, T["bg_dot"])

    # Determine offset for pose
    dx, dy = 0, 0
    if pose == "tilt_left":
        dx = -1
    elif pose == "peek_right":
        dx = -2

    def R(x0,y0,x1,y1,c): rect(px, x0+dx, y0+dy, x1+dx, y1+dy, c)
    def F(x,y,c): fill(px, x+dx, y+dy, c)

    # ears (triangular)
    # left ear
    for i, span in enumerate([(8,8),(8,8),(8,9),(8,10)]):
        x0, x1 = span
        R(x0, 5+i, x1+i, 5+i, T["ink"]) if False else None
    # simpler: explicit pixels
    left_ear_outline = [(7,5),(7,6),(7,7),(8,4),(8,3),(9,4),(9,5),(10,5),(10,6)]
    left_ear_fill = [(8,5),(8,6),(8,7),(9,6),(9,7),(10,7)]
    right_ear_outline = [(24,5),(24,6),(24,7),(23,4),(23,3),(22,4),(22,5),(21,5),(21,6)]
    right_ear_fill = [(23,5),(23,6),(23,7),(22,6),(22,7),(21,7)]
    for x,y in left_ear_outline + right_ear_outline:
        F(x, y, T["ink"])
    for x,y in left_ear_fill + right_ear_fill:
        F(x, y, T["body"])
    # inner ear (pink)
    for x,y in [(9,5),(9,6)]:
        F(x, y, T["ear_inner"])
    for x,y in [(22,5),(22,6)]:
        F(x, y, T["ear_inner"])

    # cube body
    R(7, 7, 24, 26, T["body"])
    # body shading (right + bottom)
    for y in range(7, 27):
        F(24, y, T["body_d"])
        F(23, y, T["body_d"]) if y >= 24 else None
    for x in range(7, 25):
        F(x, 26, T["body_d"])
    # outline
    R(7, 6, 24, 6, T["ink"])
    R(7, 27, 24, 27, T["ink"])
    R(6, 7, 6, 26, T["ink"])
    R(25, 7, 25, 26, T["ink"])

    # CRT screen frame
    R(9, 10, 22, 21, T["screen_frame"])
    R(10, 11, 21, 20, T["screen_bg"])
    # scanlines
    for y in range(12, 20, 2):
        for x in range(10, 22):
            r,g,b,a = T["screen_bg"]
            F(x, y, (max(0,r-12), max(0,g-12), max(0,b-12), 255))

    # Face on screen
    if face == "happy":
        # ^ ^ closed eyes
        for x,y in [(12,13),(13,14),(14,13)]:
            F(x, y, T["face"])
        for x,y in [(17,13),(18,14),(19,13)]:
            F(x, y, T["face"])
        # nose
        F(15, 16, T["nose"]); F(16, 16, T["nose"])
        # smile w-shape
        for x,y in [(13,17),(14,18),(15,17),(16,17),(17,18),(18,17)]:
            F(x, y, T["face"])
        # whiskers
        F(11, 16, T["face"]); F(20, 16, T["face"])
    elif face == "wink":
        # left eye open, right eye wink
        R(12, 13, 13, 15, T["face"])
        F(13, 13, T["screen_bg"])
        for x,y in [(17,14),(18,15),(19,14)]:
            F(x, y, T["face"])
        F(15, 16, T["nose"]); F(16, 16, T["nose"])
        for x,y in [(14,17),(15,18),(16,18),(17,17)]:
            F(x, y, T["face"])
    elif face == "sleepy":
        # underscore eyes
        R(12, 14, 14, 14, T["face"])
        R(17, 14, 19, 14, T["face"])
        # zZz above
        F(20, 11, T["face"]); F(21, 11, T["face"]); F(22, 11, T["face"])
        F(22, 12, T["face"]); F(21, 13, T["face"])
        F(20, 14, T["face"]); F(21, 14, T["face"]); F(22, 14, T["face"])
        # small mouth
        F(15, 17, T["face"]); F(16, 17, T["face"])
        F(15, 16, T["nose"]); F(16, 16, T["nose"])
    elif face == "smug":
        # dot eyes
        R(12, 13, 13, 14, T["face"])
        R(18, 13, 19, 14, T["face"])
        F(15, 16, T["nose"]); F(16, 16, T["nose"])
        # smirk (asymmetric)
        for x,y in [(14,18),(15,18),(16,18),(17,18),(18,17)]:
            F(x, y, T["face"])
    elif face == "excited":
        # star eyes
        for cx in (13, 18):
            F(cx, 13, T["face"])
            F(cx-1, 14, T["face"]); F(cx, 14, T["face"]); F(cx+1, 14, T["face"])
            F(cx, 15, T["face"])
        F(15, 16, T["nose"]); F(16, 16, T["nose"])
        # open smile
        R(13, 17, 18, 17, T["face"])
        R(14, 18, 17, 19, T["face"])
        F(15, 18, T["nose"]); F(16, 18, T["nose"])  # tongue

    # Bottom buttons
    R(10, 23, 12, 23, T["accent_a"])
    R(14, 23, 17, 23, T["accent_b"])
    R(19, 23, 21, 23, T["accent_c"])
    R(10, 24, 12, 24, darken(T["accent_a"], 30))
    R(14, 24, 17, 24, darken(T["accent_b"], 30))
    R(19, 24, 21, 24, darken(T["accent_c"], 30))

    # tail
    if T.get("tail"):
        tail_color = T["tail"]
        for x,y in [(26,18),(27,18),(28,17),(28,16)]:
            F(x, y, tail_color)
        for x,y in [(26,17),(26,19),(27,17),(28,18),(28,15),(27,15)]:
            F(x, y, T["ink"])

    # Power LED
    F(8, 8, T["accent_a"])


# ---------- Variant palettes ----------

INK = (40, 36, 60, 255)

V_A = {  # baseline polished — lilac body, peach bg
    "bg": (255, 200, 160, 255), "bg_dot": (230, 140, 90, 255),
    "body": (200, 180, 255, 255), "body_d": (140, 110, 220, 255),
    "screen_frame": INK, "screen_bg": (30, 50, 80, 255),
    "face": (140, 230, 200, 255),
    "accent_a": (255, 168, 188, 255),
    "accent_b": (140, 230, 200, 255),
    "accent_c": (255, 226, 130, 255),
    "ear_inner": (255, 168, 188, 255),
    "nose": (255, 168, 188, 255),
    "ink": INK,
    "tail": (200, 180, 255, 255),
}

V_B = {  # dark/cyber — navy body, neon
    "bg": (28, 30, 50, 255), "bg_dot": (60, 70, 110, 255),
    "body": (70, 80, 130, 255), "body_d": (45, 55, 95, 255),
    "screen_frame": (10, 12, 20, 255), "screen_bg": (15, 25, 45, 255),
    "face": (110, 255, 220, 255),
    "accent_a": (255, 100, 160, 255),
    "accent_b": (110, 255, 220, 255),
    "accent_c": (255, 220, 90, 255),
    "ear_inner": (255, 100, 160, 255),
    "nose": (255, 100, 160, 255),
    "ink": (10, 12, 20, 255),
    "tail": (70, 80, 130, 255),
}

V_C = {  # warm chill — pink body, mint bg, sleepy
    "bg": (180, 240, 220, 255), "bg_dot": (110, 200, 180, 255),
    "body": (255, 180, 200, 255), "body_d": (220, 120, 160, 255),
    "screen_frame": INK, "screen_bg": (50, 30, 60, 255),
    "face": (255, 230, 140, 255),
    "accent_a": (255, 230, 140, 255),
    "accent_b": (200, 180, 255, 255),
    "accent_c": (140, 220, 255, 255),
    "ear_inner": (255, 220, 230, 255),
    "nose": (220, 120, 160, 255),
    "ink": INK,
    "tail": (255, 180, 200, 255),
}

V_D = {  # gameboy-ish — yellow body green screen
    "bg": (250, 220, 100, 255), "bg_dot": (220, 180, 60, 255),
    "body": (255, 240, 160, 255), "body_d": (210, 180, 80, 255),
    "screen_frame": (80, 60, 30, 255), "screen_bg": (140, 180, 80, 255),
    "face": (40, 60, 30, 255),
    "accent_a": (220, 80, 80, 255),
    "accent_b": (60, 130, 180, 255),
    "accent_c": (240, 200, 60, 255),
    "ear_inner": (255, 200, 200, 255),
    "nose": (220, 100, 100, 255),
    "ink": (60, 40, 20, 255),
    "tail": (255, 240, 160, 255),
}

V_E = {  # minimal modern — sky body, clean bg, big bold
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


def make(name, theme, face, bg_pattern):
    img, px = new_canvas(theme["bg"])
    draw_cat_cube(px, theme, face=face, bg_pattern=bg_pattern)
    finalize(img, name)


def contact_sheet():
    names = ["v1_lilac_happy","v2_cyber_smug","v3_pink_sleepy","v4_gameboy_wink","v5_clean_excited"]
    thumb = 384
    pad = 24
    cols = 5
    W = cols * thumb + (cols + 1) * pad
    H = thumb + 2 * pad + 60
    sheet = Image.new("RGBA", (W, H), (250, 248, 244, 255))
    draw = ImageDraw.Draw(sheet)
    for i, n in enumerate(names):
        im = Image.open(os.path.join(OUT, f"{n}.png")).resize((thumb, thumb), Image.NEAREST)
        sheet.paste(im, (pad + i * (thumb + pad), pad), im)
        draw.text((pad + i * (thumb + pad) + 12, pad + thumb + 10), n, fill=(40,36,60,255))
    sheet.save(os.path.join(OUT, "00_variants_sheet.png"))


make("v1_lilac_happy",    V_A, "happy",   "dots")
make("v2_cyber_smug",     V_B, "smug",    "sparkle")
make("v3_pink_sleepy",    V_C, "sleepy",  "stripes")
make("v4_gameboy_wink",   V_D, "wink",    "dots")
make("v5_clean_excited",  V_E, "excited", "none")
contact_sheet()
print("done")
