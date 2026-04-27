"""Generate 5 pixel-art icon drafts for VibeBuddy.

Each icon is designed on a small pixel grid (32x32 art canvas)
then nearest-neighbor scaled up to 1024x1024 for iOS/macOS use.
A subtle rounded background is applied (iOS will mask anyway).
"""
from PIL import Image, ImageDraw, ImageFilter
import os

OUT = os.path.dirname(os.path.abspath(__file__))
GRID = 32           # art canvas
SCALE = 32          # 32 * 32 = 1024 px
SIZE = GRID * SCALE
RADIUS = 224        # rounded square for preview only (~iOS mask)

# ---------- helpers ----------

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

def circle(px, cx, cy, r, c):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            dx, dy = x - cx, y - cy
            if dx * dx + dy * dy <= r * r:
                fill(px, x, y, c)

def ring(px, cx, cy, r, c):
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - r, cx + r + 1):
            dx, dy = x - cx, y - cy
            d2 = dx * dx + dy * dy
            if (r - 1) * (r - 1) < d2 <= r * r:
                fill(px, x, y, c)

def finalize(img, name):
    big = img.resize((SIZE, SIZE), Image.NEAREST)
    # rounded preview mask (so it looks like an app icon)
    mask = Image.new("L", (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, SIZE, SIZE), radius=RADIUS, fill=255)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(big, (0, 0), mask)
    out.save(os.path.join(OUT, f"{name}.png"))
    # also save the un-masked square (full bleed) for actual iconset use later
    big.save(os.path.join(OUT, f"{name}_square.png"))


# ---------- palette ----------
# Soft, modern, slightly retro — not GameBoy-green to feel like a buddy
P = {
    "ink": (40, 36, 60, 255),
    "shadow": (70, 64, 100, 255),
    "white": (245, 244, 252, 255),
    "cream": (255, 240, 220, 255),
    "pink": (255, 168, 188, 255),
    "pink_d": (220, 110, 140, 255),
    "mint": (140, 230, 200, 255),
    "mint_d": (70, 180, 160, 255),
    "lemon": (255, 226, 130, 255),
    "lemon_d": (235, 180, 60, 255),
    "sky": (160, 210, 255, 255),
    "sky_d": (90, 150, 230, 255),
    "lilac": (200, 180, 255, 255),
    "lilac_d": (140, 110, 220, 255),
    "peach": (255, 200, 160, 255),
    "peach_d": (230, 140, 90, 255),
    "blush": (255, 180, 190, 255),
}


# =====================================================
# Design 1: Classic Tamagotchi egg (lemon body, mint cheeks)
# An egg-shaped buddy with a tiny screen-style face.
# =====================================================
def design1():
    img, px = new_canvas(P["mint"])
    # background subtle dots pattern
    for y in range(0, GRID, 4):
        for x in range(0, GRID, 4):
            fill(px, x, y, P["mint_d"])

    # egg body (lemon)
    egg_color = P["lemon"]
    egg_shadow = P["lemon_d"]
    body = [
        (12,5,19,5),(11,6,20,6),(10,7,21,7),(9,8,22,8),
        (8,9,23,9),(8,10,23,10),(7,11,24,11),(7,12,24,12),
        (7,13,24,13),(7,14,24,14),(6,15,25,15),(6,16,25,16),
        (6,17,25,17),(6,18,25,18),(7,19,24,19),(7,20,24,20),
        (7,21,24,21),(8,22,23,22),(8,23,23,23),(9,24,22,24),
        (10,25,21,25),(11,26,20,26),(13,27,18,27),
    ]
    for x0,y0,x1,y1 in body:
        rect(px, x0, y0, x1, y1, egg_color)
    # outline
    outline = [
        (12,4),(13,4),(14,4),(15,4),(16,4),(17,4),(18,4),(19,4),
        (11,5),(20,5),(10,6),(21,6),(9,7),(22,7),(8,8),(23,8),
        (7,9),(7,10),(24,9),(24,10),(6,11),(6,12),(6,13),(6,14),
        (25,11),(25,12),(25,13),(25,14),(5,15),(5,16),(5,17),(5,18),
        (26,15),(26,16),(26,17),(26,18),(6,19),(6,20),(6,21),
        (25,19),(25,20),(25,21),(7,22),(7,23),(24,22),(24,23),
        (8,24),(23,24),(9,25),(22,25),(10,26),(21,26),
        (12,27),(19,27),(13,28),(14,28),(15,28),(16,28),(17,28),(18,28),
    ]
    for x,y in outline:
        fill(px, x, y, P["ink"])
    # screen / face area (rounded rect of cream)
    rect(px, 11, 11, 20, 19, P["cream"])
    fill(px, 10, 12, P["cream"]); fill(px, 10, 13, P["cream"]); fill(px, 10, 14, P["cream"]); fill(px, 10, 15, P["cream"]); fill(px, 10, 16, P["cream"]); fill(px, 10, 17, P["cream"]); fill(px, 10, 18, P["cream"])
    fill(px, 21, 12, P["cream"]); fill(px, 21, 13, P["cream"]); fill(px, 21, 14, P["cream"]); fill(px, 21, 15, P["cream"]); fill(px, 21, 16, P["cream"]); fill(px, 21, 17, P["cream"]); fill(px, 21, 18, P["cream"])
    # face: two eyes + smile
    rect(px, 13, 14, 14, 15, P["ink"])
    rect(px, 17, 14, 18, 15, P["ink"])
    # smile
    fill(px, 14, 17, P["ink"]); fill(px, 15, 18, P["ink"]); fill(px, 16, 18, P["ink"]); fill(px, 17, 17, P["ink"])
    # cheeks
    fill(px, 12, 16, P["pink"]); fill(px, 19, 16, P["pink"])
    # antenna with heart
    fill(px, 15, 3, P["ink"]); fill(px, 16, 3, P["ink"])
    fill(px, 14, 2, P["pink_d"]); fill(px, 15, 2, P["pink_d"]); fill(px, 16, 2, P["pink_d"]); fill(px, 17, 2, P["pink_d"])
    fill(px, 14, 1, P["pink"]); fill(px, 17, 1, P["pink"])
    fill(px, 15, 1, P["pink_d"]); fill(px, 16, 1, P["pink_d"])
    finalize(img, "01_tamagotchi_egg")


# =====================================================
# Design 2: Pixel Robot Buddy (boxy head with screen face)
# Like a tiny retro robot pal.
# =====================================================
def design2():
    img, px = new_canvas(P["sky"])
    # diagonal stripes background
    for y in range(GRID):
        for x in range(GRID):
            if (x + y) % 6 == 0:
                fill(px, x, y, P["sky_d"])

    # antenna
    fill(px, 15, 3, P["ink"]); fill(px, 16, 3, P["ink"])
    fill(px, 15, 4, P["ink"]); fill(px, 16, 4, P["ink"])
    circle(px, 15, 2, 1, P["lemon"])
    fill(px, 15, 1, P["lemon_d"])

    # head box
    rect(px, 7, 6, 24, 22, P["lilac"])
    rect(px, 8, 5, 23, 5, P["lilac"])
    rect(px, 8, 23, 23, 23, P["lilac"])
    # outline
    rect(px, 8, 4, 23, 4, P["ink"])
    rect(px, 8, 24, 23, 24, P["ink"])
    rect(px, 6, 6, 6, 22, P["ink"])
    rect(px, 25, 6, 25, 22, P["ink"])
    fill(px, 7, 5, P["ink"]); fill(px, 24, 5, P["ink"])
    fill(px, 7, 23, P["ink"]); fill(px, 24, 23, P["ink"])
    # screen
    rect(px, 9, 8, 22, 18, P["ink"])
    rect(px, 10, 9, 21, 17, (20, 30, 60, 255))
    # face on screen (mint pixels)
    # eyes
    rect(px, 12, 11, 13, 13, P["mint"])
    rect(px, 18, 11, 19, 13, P["mint"])
    fill(px, 13, 12, P["white"]); fill(px, 19, 12, P["white"])
    # smile
    fill(px, 13, 15, P["mint"]); fill(px, 14, 16, P["mint"]); fill(px, 15, 16, P["mint"]); fill(px, 16, 16, P["mint"]); fill(px, 17, 16, P["mint"]); fill(px, 18, 15, P["mint"])
    # buttons
    circle(px, 11, 21, 1, P["pink_d"])
    circle(px, 15, 21, 1, P["mint_d"])
    circle(px, 19, 21, 1, P["lemon_d"])
    # ears (side)
    rect(px, 4, 11, 5, 14, P["lilac_d"])
    rect(px, 26, 11, 27, 14, P["lilac_d"])
    rect(px, 4, 10, 5, 10, P["ink"]); rect(px, 4, 15, 5, 15, P["ink"])
    rect(px, 26, 10, 27, 10, P["ink"]); rect(px, 26, 15, 27, 15, P["ink"])
    fill(px, 3, 11, P["ink"]); fill(px, 3, 12, P["ink"]); fill(px, 3, 13, P["ink"]); fill(px, 3, 14, P["ink"])
    fill(px, 28, 11, P["ink"]); fill(px, 28, 12, P["ink"]); fill(px, 28, 13, P["ink"]); fill(px, 28, 14, P["ink"])
    # body hint at bottom
    rect(px, 11, 25, 20, 27, P["lilac_d"])
    rect(px, 10, 25, 10, 27, P["ink"])
    rect(px, 21, 25, 21, 27, P["ink"])
    rect(px, 11, 28, 20, 28, P["ink"])
    finalize(img, "02_robot_buddy")


# =====================================================
# Design 3: Ghost / blob Buddy (cute floating creature)
# Soft round body with little arms — friendly mascot.
# =====================================================
def design3():
    img, px = new_canvas(P["lilac"])
    # subtle stars
    for x, y in [(4,5),(27,7),(6,24),(25,22),(3,14),(28,15),(10,3),(22,28)]:
        fill(px, x, y, P["white"])
        fill(px, x+1, y, P["white"])
        fill(px, x, y+1, P["white"])

    # ghost body (peach)
    # top half circle
    body_rows = [
        (10,8,21,8),(8,9,23,9),(7,10,24,10),(6,11,25,11),(6,12,25,12),
        (5,13,26,13),(5,14,26,14),(5,15,26,15),(5,16,26,16),(5,17,26,17),
        (5,18,26,18),(5,19,26,19),(5,20,26,20),(5,21,26,21),(5,22,26,22),
        (5,23,26,23),
    ]
    for x0,y0,x1,y1 in body_rows:
        rect(px, x0, y0, x1, y1, P["peach"])
    # wavy bottom
    rect(px, 5, 24, 7, 24, P["peach"])
    rect(px, 9, 24, 12, 24, P["peach"])
    rect(px, 14, 24, 17, 24, P["peach"])
    rect(px, 19, 24, 22, 24, P["peach"])
    rect(px, 24, 24, 26, 24, P["peach"])
    rect(px, 5, 25, 6, 25, P["peach"])
    rect(px, 10, 25, 11, 25, P["peach"])
    rect(px, 15, 25, 16, 25, P["peach"])
    rect(px, 20, 25, 21, 25, P["peach"])
    rect(px, 25, 25, 26, 25, P["peach"])

    # outline
    out = [
        (10,7),(11,7),(12,7),(13,7),(14,7),(15,7),(16,7),(17,7),(18,7),(19,7),(20,7),(21,7),
        (8,8),(9,8),(22,8),(23,8),(7,9),(24,9),(6,10),(25,10),
        (5,11),(5,12),(26,11),(26,12),(4,13),(4,14),(4,15),(4,16),(4,17),(4,18),(4,19),(4,20),(4,21),(4,22),(4,23),
        (27,13),(27,14),(27,15),(27,16),(27,17),(27,18),(27,19),(27,20),(27,21),(27,22),(27,23),
        # bottom waves outline
        (5,26),(6,26),(7,25),(8,24),(8,25),(9,25),(10,26),(11,26),(12,25),(13,24),(13,25),(14,25),(15,26),(16,26),(17,25),(18,24),(18,25),(19,25),(20,26),(21,26),(22,25),(23,24),(23,25),(24,25),(25,26),(26,26),
    ]
    for x,y in out: fill(px, x, y, P["ink"])

    # face
    # eyes (big sparkle)
    rect(px, 10, 14, 12, 17, P["ink"])
    rect(px, 19, 14, 21, 17, P["ink"])
    fill(px, 11, 15, P["white"]); fill(px, 20, 15, P["white"])
    # blush
    rect(px, 8, 18, 9, 19, P["pink"])
    rect(px, 22, 18, 23, 19, P["pink"])
    # smile (open happy)
    rect(px, 13, 19, 18, 19, P["ink"])
    rect(px, 14, 20, 17, 21, P["ink"])
    rect(px, 15, 20, 16, 20, P["pink_d"])  # tongue
    # little arm waves
    rect(px, 3, 17, 4, 17, P["peach"])
    fill(px, 2, 17, P["ink"]); fill(px, 3, 16, P["ink"]); fill(px, 3, 18, P["ink"]); fill(px, 4, 18, P["ink"])
    rect(px, 27, 17, 28, 17, P["peach"])
    fill(px, 29, 17, P["ink"]); fill(px, 28, 16, P["ink"]); fill(px, 27, 18, P["ink"]); fill(px, 28, 18, P["ink"])
    finalize(img, "03_ghost_blob")


# =====================================================
# Design 4: Pixel Heart Buddy (heart-shaped body, smiling)
# "Buddy" = friend = heart. Warm, affectionate.
# =====================================================
def design4():
    img, px = new_canvas(P["cream"])
    # checker faint
    for y in range(GRID):
        for x in range(GRID):
            if (x // 2 + y // 2) % 2 == 0:
                pass
            else:
                r,g,b,a = P["cream"]
                fill(px, x, y, (r-8, g-12, b-18, 255))

    # heart shape (pink)
    heart_rows = {
        6:  [(8,12),(17,21)],
        7:  [(7,13),(16,22)],
        8:  [(6,14),(15,23)],
        9:  [(6,23)],
        10: [(5,24)],
        11: [(5,24)],
        12: [(5,24)],
        13: [(5,24)],
        14: [(6,23)],
        15: [(6,23)],
        16: [(7,22)],
        17: [(8,21)],
        18: [(9,20)],
        19: [(10,19)],
        20: [(11,18)],
        21: [(12,17)],
        22: [(13,16)],
        23: [(14,15)],
    }
    for y, spans in heart_rows.items():
        for x0,x1 in spans:
            rect(px, x0, y, x1, y, P["pink"])

    # darker shadow on right side
    for y, spans in heart_rows.items():
        for x0,x1 in spans:
            # shadow on right edge
            fill(px, x1, y, P["pink_d"])
            if x1-1 >= x0:
                fill(px, x1-1, y, P["pink_d"])

    # highlight on left top lobe
    for x,y in [(8,8),(9,8),(8,9),(9,9),(10,9)]:
        fill(px, x, y, P["blush"])
    for x,y in [(7,10),(8,10),(9,10)]:
        fill(px, x, y, P["white"])

    # outline (simple)
    outline_pts = []
    # build outline by scanning rows
    rows = sorted(heart_rows.keys())
    # top edges
    for y, spans in heart_rows.items():
        for x0,x1 in spans:
            outline_pts.append((x0-1, y))
            outline_pts.append((x1+1, y))
    # top of lobes
    for x in range(8,12): outline_pts.append((x,5))
    for x in range(17,22): outline_pts.append((x,5))
    outline_pts += [(7,6),(12,6),(13,6),(16,6),(22,6)]
    outline_pts += [(6,7),(13,7),(16,7),(23,7)]
    outline_pts += [(5,8),(24,8)]
    outline_pts += [(5,9),(24,9)]
    outline_pts += [(4,10),(4,11),(4,12),(4,13),(25,10),(25,11),(25,12),(25,13)]
    outline_pts += [(5,14),(24,14),(5,15),(24,15)]
    # bottom point
    outline_pts += [(15,24),(16,24)]
    for x,y in outline_pts:
        # only paint outline if not already body
        if 0 <= x < GRID and 0 <= y < GRID:
            r = px[x,y]
            if r != P["pink"] and r != P["pink_d"] and r != P["blush"] and r != P["white"]:
                fill(px, x, y, P["ink"])

    # face (eyes + smile) center around (15-16, 12-14)
    # eyes
    rect(px, 11, 11, 12, 13, P["ink"])
    rect(px, 18, 11, 19, 13, P["ink"])
    fill(px, 12, 11, P["white"]); fill(px, 19, 11, P["white"])
    # smile
    fill(px, 13, 15, P["ink"]); fill(px, 14, 16, P["ink"]); fill(px, 15, 16, P["ink"]); fill(px, 16, 16, P["ink"]); fill(px, 17, 15, P["ink"])
    # cheeks
    fill(px, 10, 14, P["pink_d"]); fill(px, 20, 14, P["pink_d"])

    # sparkles
    for x,y in [(3,4),(27,5),(4,20),(26,22)]:
        fill(px, x, y, P["lemon_d"])
        fill(px, x+1, y, P["lemon"])
        fill(px, x, y+1, P["lemon"])

    finalize(img, "04_heart_buddy")


# =====================================================
# Design 5: Cat-cube Buddy (cube body with cat ears, retro CRT face)
# Mash-up of pet + tech — nice for "vibe-buddy".
# =====================================================
def design5():
    img, px = new_canvas(P["peach"])
    # gradient-ish dots
    for y in range(GRID):
        for x in range(GRID):
            if (x*7 + y*3) % 11 == 0:
                fill(px, x, y, P["peach_d"])

    # ears (triangles)
    for i in range(4):
        rect(px, 7+i, 6-i if 6-i>=2 else 2, 7+i, 8, P["ink"])
    # left ear filled
    triangle_left = [(8,6),(8,7),(8,8),(9,7),(9,8),(10,8)]
    for x,y in triangle_left: fill(px, x, y, P["lilac"])
    # right ear
    for i in range(4):
        rect(px, 24-i, 6-i if 6-i>=2 else 2, 24-i, 8, P["ink"])
    triangle_right = [(23,6),(23,7),(23,8),(22,7),(22,8),(21,8)]
    for x,y in triangle_right: fill(px, x, y, P["lilac"])

    # cube body
    rect(px, 7, 8, 24, 25, P["lilac"])
    # outline
    rect(px, 6, 8, 6, 25, P["ink"])
    rect(px, 25, 8, 25, 25, P["ink"])
    rect(px, 7, 7, 24, 7, P["ink"])
    rect(px, 7, 26, 24, 26, P["ink"])
    # rounded corners (ink)
    fill(px, 6, 7, P["ink"]); fill(px, 25, 7, P["ink"])
    fill(px, 6, 26, P["ink"]); fill(px, 25, 26, P["ink"])

    # CRT screen
    rect(px, 9, 11, 22, 22, P["ink"])
    rect(px, 10, 12, 21, 21, (30, 50, 80, 255))
    # scanlines
    for y in range(13, 21, 2):
        for x in range(10, 22):
            r,g,b,a = px[x,y]
            fill(px, x, y, (max(0,r-15), max(0,g-15), max(0,b-15), 255))

    # cat face on screen
    # eyes (closed happy >  <)
    fill(px, 12, 14, P["mint"]); fill(px, 13, 15, P["mint"]); fill(px, 14, 14, P["mint"])
    fill(px, 17, 14, P["mint"]); fill(px, 18, 15, P["mint"]); fill(px, 19, 14, P["mint"])
    # nose + mouth (cat 'w')
    fill(px, 15, 17, P["pink"]); fill(px, 16, 17, P["pink"])
    fill(px, 14, 18, P["mint"]); fill(px, 15, 19, P["mint"]); fill(px, 16, 19, P["mint"]); fill(px, 17, 18, P["mint"])
    fill(px, 13, 18, P["mint"]); fill(px, 18, 18, P["mint"])
    # whiskers
    fill(px, 11, 17, P["mint_d"]); fill(px, 20, 17, P["mint_d"])

    # bottom buttons
    rect(px, 10, 24, 12, 24, P["pink"])
    rect(px, 14, 24, 17, 24, P["mint"])
    rect(px, 19, 24, 21, 24, P["lemon"])
    rect(px, 10, 23, 12, 23, P["pink_d"])
    rect(px, 14, 23, 17, 23, P["mint_d"])
    rect(px, 19, 23, 21, 23, P["lemon_d"])

    # tail peek (right side)
    fill(px, 26, 18, P["lilac"]); fill(px, 27, 18, P["lilac"]); fill(px, 28, 17, P["lilac"]); fill(px, 28, 16, P["lilac"])
    fill(px, 26, 17, P["ink"]); fill(px, 26, 19, P["ink"]); fill(px, 27, 17, P["ink"]); fill(px, 28, 18, P["ink"]); fill(px, 28, 15, P["ink"]); fill(px, 27, 15, P["ink"])

    finalize(img, "05_cat_cube")


def make_contact_sheet():
    names = ["01_tamagotchi_egg","02_robot_buddy","03_ghost_blob","04_heart_buddy","05_cat_cube"]
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
    sheet.save(os.path.join(OUT, "00_contact_sheet.png"))


design1()
design2()
design3()
design4()
design5()
make_contact_sheet()
print("done")
