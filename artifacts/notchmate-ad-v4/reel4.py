"""NotchMate Reel v4: hook-first, kinetic captions, camera punch-ins. 1080x1920 @ 30 fps."""
import importlib.util
import json
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path("/Users/aleksandrkezikov/my_project/dock")
HERE = Path(__file__).resolve().parent
OUT = Path(sys.argv[1])
PREVIEW = sys.argv[2:]

spec = importlib.util.spec_from_file_location("ra", ROOT / "tools/readme_art.py")
ra = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ra)

W, H, FPS = 1080, 1920, 30
ORANGE = (255, 159, 10)
YELLOW = (255, 214, 10)

def font(size, weight="Bold", path="/System/Library/Fonts/SFNSRounded.ttf"):
    f = ImageFont.truetype(path, size)
    f.set_variation_by_name(weight)
    return f

def clamp(x):
    return min(max(x, 0.0), 1.0)

def ease_out(x):
    return 1 - (1 - clamp(x)) ** 3

def ease_back(x, s=1.6):
    x = clamp(x) - 1
    return x * x * ((s + 1) * x + s) + 1

def ease_io(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)

def lerp(a, b, k):
    return a + (b - a) * k

def fade(im, a):
    if a >= 1:
        return im
    im = im.copy()
    im.putalpha(im.getchannel("A").point(lambda v: int(v * a)))
    return im

# MARK: timeline from the voice segments

SEGS = json.loads((HERE / "segs.json").read_text())
KEYS = ["hook", "music", "assistant", "notes", "health", "hello", "dance", "brand", "link", "save"]
GAP = {7: 0.35}  # a breath before the brand card
t = 0.35
for i, s in enumerate(SEGS):
    t += GAP.get(i, 0.0 if i == 0 else 0.16)
    s["start"] = t
    s["key"] = KEYS[i]
    t += s["dur"]
END_HOLD = 0.9
LOOP = 0.45  # collapse back to the opening frame so the reel loops seamlessly
TOTAL = round(t + END_HOLD + LOOP, 2)
# visual cuts land a beat before the voice
CUTS = [0.0] + [s["start"] - 0.08 for s in SEGS[1:]]

def seg_at(tt):
    k = 0
    for i, c in enumerate(CUTS):
        if tt >= c:
            k = i
    return k, tt - CUTS[k]

# MARK: background + display

def make_bg():
    small = Image.new("RGB", (160, 280), (6, 6, 11))
    d = ImageDraw.Draw(small)
    for (x, y, r, c) in [(10, 20, 55, (60, 25, 120)), (150, 60, 50, (0, 65, 90)),
                         (20, 270, 70, (80, 20, 75)), (150, 250, 50, (20, 30, 100))]:
        d.ellipse((x - r, y - r, x + r, y + r), fill=c)
    return small.filter(ImageFilter.GaussianBlur(28)).resize((W + 200, H + 200), Image.BICUBIC)

BG = make_bg()
DX, DY, DW, DH = -44, 330, 1140, 760
NOTCH_W, NOTCH_H = 190, 40

def make_display():
    img = Image.new("RGBA", (DW + 28, DH + 14), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, DW + 27, DH + 40), 48, fill=(24, 24, 28, 255))
    d.rounded_rectangle((1, 1, DW + 26, DH + 40), 47, outline=(70, 70, 80, 255), width=2)
    wall = Image.new("RGB", (100, 82), (0, 0, 0))
    wd = ImageDraw.Draw(wall)
    wd.ellipse((-40, -20, 45, 80), fill=(80, 40, 160))
    wd.ellipse((60, 0, 150, 90), fill=(0, 105, 130))
    wd.ellipse((25, 55, 80, 110), fill=(70, 25, 80))
    wall = wall.filter(ImageFilter.GaussianBlur(14)).resize((DW, DH), Image.BICUBIC)
    mask = Image.new("L", (DW, DH), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, DW - 1, DH + 40), 36, fill=255)
    img.paste(wall, (14, 14), mask)
    img.alpha_composite(Image.new("RGBA", (DW, 44), (255, 255, 255, 22)), (14, 14))
    d = ImageDraw.Draw(img)
    fb = font(23, "Bold", "/System/Library/Fonts/SFNS.ttf")
    fr = font(23, "Regular", "/System/Library/Fonts/SFNS.ttf")
    d.text((94, 22), "Finder", font=fb, fill=(255, 255, 255))
    d.text((184, 22), "Файл    Правка    Вид", font=fr, fill=(235, 235, 240))
    tm = "Ср 16 сент. 9:41"
    d.text((DW - 60 - d.textlength(tm, font=fr), 22), tm, font=fr, fill=(235, 235, 240))
    fadeh = 300
    grad = Image.linear_gradient("L").resize((img.width, fadeh)).point(lambda v: 255 - v)
    full = Image.new("L", img.size, 255)
    full.paste(grad, (0, img.height - fadeh))
    img.putalpha(ImageChops.multiply(img.getchannel("A"), full))
    return img

DISPLAY = make_display()

# MARK: panel contents

PANEL_W = 1040
SCALE = PANEL_W / 1262
PX0, PY0 = DX + 14 + (DW - PANEL_W) // 2, DY + 14

def panel(name):
    src = Image.open(ROOT / f"docs/images/{name}.png").convert("RGB")
    rows = {"assistant": 611, "music": 443, "notes": 839, "health": 591}[name]
    return src.crop((369, 0, 1631, rows)).resize((PANEL_W, round(rows * SCALE)), Image.LANCZOS).convert("RGBA")

PANELS = {n: panel(n) for n in ["music", "assistant", "notes", "health"]}
FACES = {n: ra.frames(n) for n in ["happy", "excited", "dance_bob", "dance_jump", "wink", "love"]}

def face_panel(name, tt, size=(820, 470), scale=6):
    fs, fps = FACES[name]
    f = fs[int(tt * fps) % len(fs)]
    f = f.resize((f.width * scale, f.height * scale), Image.NEAREST)
    im = Image.new("RGBA", size, (0, 0, 0, 255))
    im.alpha_composite(f, ((size[0] - f.width) // 2, (size[1] - f.height) // 2 + 20))
    return im

def content(key, tt):
    if key in PANELS:
        return PANELS[key]
    if key == "hello":
        return face_panel("excited" if tt < 1.0 else "happy", tt)
    if key == "dance":
        return face_panel("dance_jump" if int(tt / 0.9) % 2 else "dance_bob", tt)
    if key == "wink":
        return face_panel("wink", tt, (520, 300), 4)
    raise KeyError(key)

def size_of(key, tt):
    if key == "notch":
        return NOTCH_W, NOTCH_H
    c = content(key, tt)
    return c.width, c.height

# panel state machine: (start, key, morph seconds)
seg = {s["key"]: s for s in SEGS}
def word_time(key, idx):
    return seg[key]["start"] + seg[key]["words"][idx][0]

STATES = [(0.0, "notch", 0.2), (0.28, "music", 0.26), (0.95, "assistant", 0.2), (1.5, "notes", 0.2),
          (2.05, "health", 0.2), (2.6, "music", 0.2),
          (CUTS[1], "notch", 0.22), (word_time("music", 3) - 0.05, "music", 0.3),
          (CUTS[2], "assistant", 0.22), (CUTS[3], "notes", 0.22), (CUTS[4], "health", 0.22),
          (CUTS[5], "hello", 0.3), (CUTS[6], "dance", 0.22),
          (CUTS[7], "notch", 0.3), (TOTAL - LOOP, "notch", 0.35)]
FLASHES = [0.28, 0.95, 1.5, 2.05, 2.6, word_time("music", 3) - 0.05] + CUTS[2:8]

def panel_layer(tt):
    idx = max(i for i, s in enumerate(STATES) if tt >= s[0])
    t0, key, morph = STATES[idx]
    prev = STATES[idx - 1][1] if idx else "notch"
    k = (tt - t0) / morph
    if k >= 1 or idx == 0:
        prev, k = key, 1.0
    grow = ease_back(k, 1.2) if key != "notch" else ease_io(k)
    w0, h0 = size_of(prev, tt)
    w1, h1 = size_of(key, tt)
    w, h = max(2, round(lerp(w0, w1, grow))), max(2, round(lerp(h0, h1, grow)))
    layer = Image.new("RGBA", (max(w, w0, w1), max(h, h0, h1)), (0, 0, 0, 255))
    cx = layer.width // 2
    for kk, alpha in ((prev, 1 - ease_io(k * 1.6)), (key, ease_io((k - 0.1) * 1.8))):
        if kk == "notch" or alpha <= 0.01:
            continue
        layer.alpha_composite(fade(content(kk, tt), alpha), (cx - content(kk, tt).width // 2, 0))
    lx = (layer.width - w) // 2
    layer = layer.crop((lx, 0, lx + w, h))
    mask = Image.new("L", (w, h), 0)
    r = min(32 if w > 400 else 16, h // 2)
    ImageDraw.Draw(mask).rounded_rectangle((0, -r - 2, w - 1, h - 1), r, fill=255)
    layer.putalpha(mask)
    return layer, DX + 14 + (DW - w) // 2, DY + 14

GLOW = Image.new("L", (300, 220), 0)
ImageDraw.Draw(GLOW).rounded_rectangle((60, 30, 240, 190), 30, fill=255)
GLOW = GLOW.filter(ImageFilter.GaussianBlur(26))

# MARK: camera — punch on every cut, then a slow push toward the detail that matters

def focus(key):
    ph = {k: v.height for k, v in PANELS.items()}
    return {
        "music": (PX0 + 0.40 * PANEL_W, PY0 + 0.62 * ph["music"]),
        "assistant": (PX0 + 0.50 * PANEL_W, PY0 + 0.40 * ph["assistant"]),
        "notes": (PX0 + 0.74 * PANEL_W, PY0 + 0.45 * ph["notes"]),
        "health": (PX0 + 0.30 * PANEL_W, PY0 + 0.45 * ph["health"]),
    }.get(key, (W / 2, PY0 + 240))

def camera(tt):
    k, lt = seg_at(tt)
    key = KEYS[k]
    dur = (CUTS[k + 1] if k + 1 < len(CUTS) else TOTAL) - CUTS[k]
    punch = 0.07 * (1 - ease_out(lt / 0.3))
    if key == "hook":
        # punch on every quick tab switch
        last = max([f for f in FLASHES if f <= tt] or [0])
        return 1 + 0.08 * (1 - ease_out((tt - last) / 0.3)), (W / 2, PY0 + 200)
    if key == "music":
        open_t = word_time("music", 3) - 0.05 - CUTS[k]
        push = 0.32 * ease_io((lt - open_t - 0.35) / max(0.1, dur - open_t - 0.35))
        return 1 + push + punch, focus("music")
    if key in PANELS:
        return 1 + 0.30 * ease_io((lt - 0.15) / dur) + punch, focus(key)
    if key == "dance":
        beat = 60 / 120
        return 1.05 + 0.035 * abs(math.sin(math.pi * lt / beat)) + punch, (W / 2, PY0 + 240)
    return 1 + punch, (W / 2, PY0 + 240)

def apply_camera(img, s, fx, fy):
    if s <= 1.001:
        return img
    x0, y0 = fx * (1 - 1 / s), fy * (1 - 1 / s)
    return img.resize((W, H), Image.BICUBIC, box=(x0, y0, x0 + W / s, y0 + H / s))

# MARK: captions — word by word, current word pops in yellow

CAP_F = font(96, "Heavy")
CAP_Y = 1210
SPACE = CAP_F.getlength(" ") + 22

def pages(words):
    out, cur, n = [], [], 0
    for w in words:
        txt = w[2].upper()
        if cur and n + len(txt) > 15:
            out.append(cur)
            cur, n = [], 0
        cur.append((w[0], w[1], txt))
        n += len(txt) + 1
    if cur:
        out.append(cur)
    return out

def draw_caption(frame, tt):
    for s in SEGS:
        lt = tt - s["start"]
        if not (-0.05 <= lt <= s["dur"] + 0.1):
            continue
        for pg in pages(s["words"]):
            nxt_start = None
            pidx = pages(s["words"]).index(pg)
            if pidx + 1 < len(pages(s["words"])):
                nxt_start = pages(s["words"])[pidx + 1][0][0]
            if lt < pg[0][0] - 0.05 or (nxt_start is not None and lt >= nxt_start - 0.05):
                continue
            # lay the page out on up to two lines
            line, lines = [], []
            for w in pg:
                trial = " ".join(x[2] for x in line + [w])
                if line and CAP_F.getlength(trial) > 900:
                    lines.append(line)
                    line = []
                line.append(w)
            lines.append(line)
            y = CAP_Y
            for ln in lines:
                total = sum(CAP_F.getlength(x[2]) for x in ln) + SPACE * (len(ln) - 1)
                x = (W - total) / 2
                for (ws, we, txt) in ln:
                    wl = CAP_F.getlength(txt)
                    if lt >= ws - 0.04:
                        active = ws - 0.04 <= lt < we + 0.08
                        pop = ease_back((lt - ws + 0.04) / 0.18, 2.2)
                        sc = (0.6 + 0.4 * pop) * (1.08 if active else 1.0)
                        im = Image.new("RGBA", (int(wl) + 40, 140), (0, 0, 0, 0))
                        ImageDraw.Draw(im).text((20, 10), txt, font=CAP_F, fill=YELLOW if active else (255, 255, 255),
                                                stroke_width=7, stroke_fill=(0, 0, 0))
                        if abs(sc - 1) > 0.01:
                            im = im.resize((max(1, int(im.width * sc)), max(1, int(im.height * sc))), Image.BICUBIC)
                        frame.alpha_composite(im, (int(x + wl / 2 - im.width / 2), int(y + 60 - im.height / 2)))
                    x += wl + SPACE
                y += 118
            return

# MARK: stickers

EMOJI_F = ImageFont.truetype("/System/Library/Fonts/Apple Color Emoji.ttc", 160)
def emoji(ch, size):
    im = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((20, 20), ch, font=EMOJI_F, embedded_color=True)
    im = im.crop(im.getbbox())
    return im.resize((size, int(im.height * size / im.width)), Image.LANCZOS)

STICKERS = {  # key: (emoji, x, y, tilt)
    "music": ("🎧", 900, 1010, -12), "assistant": ("📅", 150, 1010, 10), "notes": ("📝", 930, 1050, 12),
    "health": ("❤️", 140, 960, -10), "hello": ("👋", 900, 900, 14), "dance": ("🕺", 160, 920, -10),
    "save": ("🔖", 900, 560, 10),
}
STICKER_IMG = {k: emoji(v[0], 150) for k, v in STICKERS.items()}

def draw_sticker(frame, tt):
    k, lt = seg_at(tt)
    key = KEYS[k]
    if key not in STICKERS:
        return
    delay = 0.25 if key != "music" else word_time("music", 3) - CUTS[k] + 0.1
    a = ease_back((lt - delay) / 0.35, 2.4)
    if a <= 0:
        return
    _, x, y, tilt = STICKERS[key]
    im = STICKER_IMG[key]
    sc = max(0.05, a)
    im = im.resize((int(im.width * sc), int(im.height * sc)), Image.BICUBIC)
    im = im.rotate(tilt + 6 * math.sin(lt * 5), expand=True, resample=Image.BICUBIC)
    bob = 10 * math.sin(lt * 4)
    if tt > TOTAL - LOOP:
        im = fade(im, 1 - ease_io((tt - (TOTAL - LOOP)) / 0.3))
    frame.alpha_composite(im, (int(x - im.width / 2), int(y - im.height / 2 + bob)))

# MARK: end card (inside the display, captions keep running below)

ICON = Image.open(ROOT / "Resources/AppIcon-source.png").convert("RGBA").resize((260, 260), Image.LANCZOS)

def end_card(frame, tt):
    t0 = CUTS[7]
    lt = tt - t0
    out = ease_io((tt - (TOTAL - LOOP)) / LOOP)
    dim = ease_io(lt / 0.3) * (1 - out)
    if dim <= 0:
        return
    frame.alpha_composite(Image.new("RGBA", (W, DH), (4, 4, 9, int(200 * dim))), (0, DY + 14))
    vis = 1 - out
    k = ease_back((lt - 0.15) / 0.45, 1.8)
    if k > 0:
        s = max(1, int(260 * k))
        frame.alpha_composite(fade(ICON.resize((s, s), Image.LANCZOS), vis), (W // 2 - s // 2, 600 - s // 2))
    a = ease_out((lt - 0.35) / 0.4) * vis
    if a > 0:
        f = font(104, "Heavy")
        im = Image.new("RGBA", (W, 130), (0, 0, 0, 0))
        ImageDraw.Draw(im).text(((W - f.getlength("NotchMate")) / 2, 0), "NotchMate", font=f, fill=(255, 255, 255))
        frame.alpha_composite(fade(im, a), (0, 760 + int(30 * (1 - a))))
    # badges
    badges = ["Бесплатно", "Open source", "8 языков"]
    fb = font(34, "Bold")
    widths = [fb.getlength(b) + 48 for b in badges]
    x = (W - sum(widths) - 16 * (len(badges) - 1)) / 2
    for j, (b, bw) in enumerate(zip(badges, widths)):
        a = ease_back((lt - 0.7 - j * 0.12) / 0.35, 2) * vis
        if a > 0:
            im = Image.new("RGBA", (int(bw), 64), (0, 0, 0, 0))
            d = ImageDraw.Draw(im)
            d.rounded_rectangle((0, 0, bw - 1, 63), 32, fill=(255, 255, 255, 34), outline=(255, 255, 255, 90), width=2)
            d.text((24, 12), b, font=fb, fill=(255, 255, 255))
            frame.alpha_composite(fade(im, min(1, a)), (int(x), 905))
        x += bw + 16
    # "link in profile" button
    lk = seg["link"]["start"] - 0.05
    a = ease_back((tt - lk) / 0.4, 1.8)
    if a > 0:
        pulse = 1 + 0.035 * math.sin(max(0, tt - lk - 0.4) * 7)
        bw, bh = int(600 * a * pulse), int(108 * a * pulse)
        btn = Image.new("RGBA", (680, 140), (0, 0, 0, 0))
        d = ImageDraw.Draw(btn)
        d.rounded_rectangle((340 - bw // 2, 70 - bh // 2, 340 + bw // 2, 70 + bh // 2), max(1, bh // 2), fill=ORANGE)
        if a > 0.75:
            f = font(46, "Heavy")
            txt = "Ссылка в профиле  →"
            d.text((340 - f.getlength(txt) / 2, 70 - 29), txt, font=f, fill=(25, 14, 0))
        frame.alpha_composite(fade(btn, vis), (W // 2 - 340, 1040 - 70))

# MARK: frame

def frame_at(tt):
    k, lt = seg_at(tt)
    ox = int(100 + 80 * math.sin(tt * 0.5))
    oy = int(100 + 80 * math.cos(tt * 0.4))
    frame = BG.crop((ox, oy, ox + W, oy + H)).convert("RGBA")
    frame.alpha_composite(DISPLAY, (DX, DY))
    layer, px, py = panel_layer(tt)
    if layer.width > 300:
        g = GLOW.resize((layer.width + 160, layer.height + 140))
        glow = Image.new("RGBA", g.size, (150, 110, 255, 0))
        glow.putalpha(g.point(lambda v: v * 80 // 255))
        frame.alpha_composite(glow, (px - 80, py - 40))
    frame.alpha_composite(layer, (px, py))
    # cursor: hook zip-in, then the "hover" in the music beat
    cur = None
    if tt < 0.3:
        kk = ease_out(tt / 0.28)
        cur = (lerp(900, W / 2 + 10, kk), lerp(1150, DY + 34, kk))
    m0 = CUTS[1]
    hover = word_time("music", 3) - 0.05
    if m0 <= tt < hover + 0.5:
        kk = ease_io((tt - m0 - 0.1) / (word_time("music", 1) + 0.3 - m0))
        cur = (lerp(860, W / 2 + 10, kk), lerp(1050, DY + 34, kk))
        if tt > hover:
            kk2 = ease_io((tt - hover) / 0.5)
            cur = (cur[0] + 500 * kk2, cur[1] + 200 * kk2)
    frame = apply_camera(frame, *((lambda s, f: (s, f[0], f[1]))(*camera(tt))))
    end_card(frame, tt)
    if cur:
        frame.alpha_composite(CURSOR, (int(cur[0]), int(cur[1])))
    # white flash on cuts
    last = max([f for f in FLASHES if f <= tt] or [-9])
    fl = 1 - clamp((tt - last) / 0.12)
    if fl > 0:
        frame.alpha_composite(Image.new("RGBA", (W, H), (255, 255, 255, int(70 * fl))))
    draw_sticker(frame, tt)
    draw_caption(frame, tt)
    return frame.convert("RGB")

CURSOR = Image.open(ROOT / "artifacts/notchmate-ad-v2/cursor.png").convert("RGBA").resize((58, 74), Image.LANCZOS)

json.dump({"total": TOTAL, "cuts": CUTS, "flashes": FLASHES, "voice": [s["start"] for s in SEGS]},
          open(HERE / "timeline.json", "w"))

if PREVIEW:
    for s in PREVIEW:
        frame_at(float(s)).save(HERE / f"prev_{s}.png")
    print("total", TOTAL)
    sys.exit()

proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "17",
                         "-pix_fmt", "yuv420p", str(OUT)], stdin=subprocess.PIPE)
n = int(TOTAL * FPS)
for i in range(n):
    proc.stdin.write(frame_at(i / FPS).tobytes())
    if i % 90 == 0:
        print(i, "/", n, flush=True)
proc.stdin.close()
proc.wait()
