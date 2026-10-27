"""NotchMate Instagram Reel v3: 1080x1920, 30 fps, raw frames piped to ffmpeg."""
import importlib.util
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path("/Users/aleksandrkezikov/my_project/dock")
OUT = Path(sys.argv[1])
PREVIEW = sys.argv[2:]  # optional list of seconds to dump as PNG instead of rendering video

spec = importlib.util.spec_from_file_location("ra", ROOT / "tools/readme_art.py")
ra = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ra)

W, H, FPS = 1080, 1920, 30
TOTAL = 27.0
ORANGE = (255, 159, 10)
ACCENTS = [(255, 159, 10), (255, 122, 180), (120, 200, 255), (130, 230, 150)]

def font(size, weight="Bold", path="/System/Library/Fonts/SFNSRounded.ttf"):
    f = ImageFont.truetype(path, size)
    f.set_variation_by_name(weight)
    return f

def ease_out(x):
    x = min(max(x, 0), 1)
    return 1 - (1 - x) ** 3

def ease_back(x, s=1.4):
    x = min(max(x, 0), 1)
    x -= 1
    return x * x * ((s + 1) * x + s) + 1

def ease_io(x):
    x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)

def lerp(a, b, k):
    return a + (b - a) * k

# MARK: background

def make_bg():
    small = Image.new("RGB", (160, 280), (7, 7, 12))
    d = ImageDraw.Draw(small)
    for (x, y, r, c) in [(10, 20, 55, (55, 25, 110)), (150, 60, 50, (0, 60, 80)),
                         (20, 270, 70, (70, 20, 70)), (150, 250, 50, (20, 30, 90))]:
        d.ellipse((x - r, y - r, x + r, y + r), fill=c)
    small = small.filter(ImageFilter.GaussianBlur(28))
    return small.resize((W + 200, H + 200), Image.BICUBIC)

BG = make_bg()

# display (the MacBook screen top)
DX, DY, DW, DH = -44, 330, 1140, 740
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
    # menu bar
    bar = Image.new("RGBA", (DW, 44), (255, 255, 255, 22))
    img.alpha_composite(bar, (14, 14))
    d = ImageDraw.Draw(img)
    fb, fr = font(23, "Bold", "/System/Library/Fonts/SFNS.ttf"), font(23, "Regular", "/System/Library/Fonts/SFNS.ttf")
    d.text((50 + 44, 22), "Finder", font=fb, fill=(255, 255, 255))
    d.text((140 + 44, 22), "Файл    Правка    Вид", font=fr, fill=(235, 235, 240))
    t = "Ср 16 сент. 9:41"
    d.text((14 + DW - 30 - 44 - d.textlength(t, font=fr), 22), t, font=fr, fill=(235, 235, 240))
    fadeh = 260
    alpha = img.getchannel("A")
    grad = Image.linear_gradient("L").resize((img.width, fadeh)).point(lambda v: 255 - v)
    full = Image.new("L", img.size, 255)
    full.paste(grad, (0, img.height - fadeh))
    img.putalpha(Image.composite(alpha, Image.new("L", img.size, 0), full) if False else Image.eval(Image.merge("LA", (alpha, full)).convert("L"), lambda v: v) if False else _mul(alpha, full))
    return img

def _mul(a, b):
    from PIL import ImageChops
    return ImageChops.multiply(a, b)

DISPLAY = make_display()

# MARK: panels

PANEL_W = 1040
SCALE = PANEL_W / 1262

def panel(name):
    src = Image.open(ROOT / f"docs/images/{name}.png").convert("RGB")
    rows = {"assistant": 611, "music": 443, "notes": 839, "health": 591, "work": 691}[name]
    im = src.crop((369, 0, 1631, rows)).resize((PANEL_W, round(rows * SCALE)), Image.LANCZOS)
    return im.convert("RGBA")

PANELS = {n: panel(n) for n in ["music", "assistant", "notes", "health"]}

FACES = {n: ra.frames(n) for n in ["happy", "excited", "dance_bob", "relax", "wink", "startup"]}

def face(name, t, scale=4):
    fs, fps = FACES[name]
    i = int(t * fps) % len(fs)
    f = fs[i]
    return f.resize((f.width * scale, f.height * scale), Image.NEAREST)

def companion_panel(name, t, label=None, size=(720, 360)):
    w, h = size
    im = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    f = face(name, t)
    y = 60 if label else (h - f.height) // 2 + 10
    im.alpha_composite(f, ((w - f.width) // 2, y))
    if label:
        d = ImageDraw.Draw(im)
        fl = font(34, "Semibold")
        d.text(((w - d.textlength(label, font=fl)) / 2, h - 70), label, font=fl, fill=(200, 230, 245))
    return im

# MARK: timeline

SCENES = [  # start, voice line, headline
    (0.0, 1, "Вырез на MacBook —\nпросто\n*чёрная полоска?*"),
    (3.1, 2, "Наведи курсор —\n*и он оживает*"),
    (5.6, 3, "*Музыка* под рукой.\nБез лишних окон."),
    (8.5, 4, "Весь день —\n*одним взглядом*"),
    (11.7, 5, "*Заметки* и списки\nвсегда рядом"),
    (14.8, 6, "*Сон, пульс, стресс* —\nпрямо с часов"),
    (17.6, 7, "Помощник\n*с характером*"),
    (22.5, 8, None),
]

def scene_at(t):
    k = 0
    for i, s in enumerate(SCENES):
        if t >= s[0]:
            k = i
    end = SCENES[k + 1][0] if k + 1 < len(SCENES) else TOTAL
    return k, t - SCENES[k][0], end - SCENES[k][0]

def content(key, t):
    """Panel content for a state key at time t → RGBA image."""
    if key == "hello":
        return companion_panel("happy", t, None, (720, 300))
    if key == "mood":
        if t < 18.9:
            return companion_panel("excited", t - 17.6, "у него есть настроение")
        if t < 20.4:
            return companion_panel("dance_bob", t - 18.9, "танцует под музыку")
        return companion_panel("relax", t - 20.4, "напоминает попить воды")
    return PANELS[key]

# panel states: (time the morph starts, key); "notch" = collapsed
STATES = [(0.0, "notch"), (4.0, "hello"), (5.6, "music"), (8.5, "assistant"),
          (11.7, "notes"), (14.8, "health"), (17.6, "mood"), (22.5, "notch")]
MORPH = 0.5

def size_of(key, t):
    if key == "notch":
        return NOTCH_W, NOTCH_H
    c = content(key, t)
    return c.width, c.height

def panel_layer(t):
    """Returns (image, x, y) of the notch/panel at time t."""
    idx = max(i for i, s in enumerate(STATES) if t >= s[0])
    t0, key = STATES[idx]
    prev = STATES[idx - 1][1] if idx else "notch"
    k = (t - t0) / MORPH
    if k >= 1 or idx == 0:
        prev, k = key, 1.0
    grow = ease_back(k, 1.1) if key != "notch" else ease_io(k)
    w0, h0 = size_of(prev, t)
    w1, h1 = size_of(key, t)
    w, h = max(2, round(lerp(w0, w1, grow))), max(2, round(lerp(h0, h1, grow)))
    layer = Image.new("RGBA", (max(w, w0, w1), max(h, h0, h1)), (0, 0, 0, 255))
    cx = layer.width // 2
    for kk, alpha in ((prev, 1 - ease_io(k * 1.4)), (key, ease_io((k - 0.15) * 1.6))):
        if kk == "notch" or alpha <= 0.01:
            continue
        c = content(kk, t)
        if alpha < 1:
            c = c.copy()
            c.putalpha(c.getchannel("A").point(lambda v: int(v * alpha)))
        layer.alpha_composite(c, (cx - c.width // 2, 0))
    lx = (layer.width - w) // 2
    layer = layer.crop((lx, 0, lx + w, h))
    mask = Image.new("L", (w, h), 0)
    r = min(30 if w > 400 else 16, h // 2)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, -r - 2, w - 1, h - 1), r, fill=255)
    layer.putalpha(mask)
    return layer, DX + 14 + (DW - w) // 2, DY + 14

GLOW = Image.new("L", (300, 220), 0)
ImageDraw.Draw(GLOW).rounded_rectangle((60, 30, 240, 190), 30, fill=255)
GLOW = GLOW.filter(ImageFilter.GaussianBlur(26))

# MARK: text

HEAD_F = font(80, "Heavy")

def render_headline(text, accent):
    lines = text.split("\n")
    out = []
    for line in lines:
        parts, on = [], False
        for seg in line.split("*"):
            if seg:
                parts.append((seg, on))
            on = not on
        tw = sum(HEAD_F.getlength(s) for s, _ in parts)
        assert tw < 1000, (line, tw)
        im = Image.new("RGBA", (int(tw) + 20, 110), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        x = 10
        for s, acc in parts:
            d.text((x, 5), s, font=HEAD_F, fill=accent if acc else (255, 255, 255))
            x += HEAD_F.getlength(s)
        out.append(im)
    return out

HEADS = [render_headline(s[2], ACCENTS[i % len(ACCENTS)]) if s[2] else None for i, s in enumerate(SCENES)]

def fade(im, a):
    if a >= 1:
        return im
    im = im.copy()
    im.putalpha(im.getchannel("A").point(lambda v: int(v * a)))
    return im

CURSOR = Image.open(ROOT / "artifacts/notchmate-ad-v2/cursor.png").convert("RGBA").resize((54, 69), Image.LANCZOS)
ICON = Image.open(ROOT / "Resources/AppIcon-source.png").convert("RGBA").resize((300, 300), Image.LANCZOS)

def end_card(frame, lt):
    d = ImageDraw.Draw(frame)
    # icon pops in the display
    k = ease_back((lt - 0.5) / 0.6, 1.6)
    if k > 0:
        s = max(1, int(300 * k))
        frame.alpha_composite(ICON.resize((s, s), Image.LANCZOS), (W // 2 - s // 2, 610 - s // 2))
    a = ease_out((lt - 0.8) / 0.5)
    if a > 0:
        f = font(110, "Heavy")
        t = "NotchMate"
        im = Image.new("RGBA", (900, 140), (0, 0, 0, 0))
        ImageDraw.Draw(im).text(((900 - f.getlength(t)) / 2, 0), t, font=f, fill=(255, 255, 255))
        frame.alpha_composite(fade(im, a), (90, 800 + int(30 * (1 - a))))
    rows = [(1.3, "Бесплатно для MacBook", 70, "Heavy", (255, 255, 255)),
            (1.6, "8 языков · данные остаются на Mac", 40, "Semibold", (190, 195, 215))]
    y = DY + DH + 90
    for t0, txt, size, wt, col in rows:
        a = ease_out((lt - t0) / 0.45)
        if a > 0:
            f = font(size, wt)
            im = Image.new("RGBA", (W, size + 30), (0, 0, 0, 0))
            ImageDraw.Draw(im).text(((W - f.getlength(txt)) / 2, 0), txt, font=f, fill=col)
            frame.alpha_composite(fade(im, a), (0, y + int(30 * (1 - a))))
        y += size + 40
    a = ease_back((lt - 2.0) / 0.5, 1.8)
    if a > 0:
        pulse = 1 + 0.04 * math.sin(max(0, lt - 2.5) * 6)
        bw, bh = int(560 * a * pulse), int(110 * a * pulse)
        x0, y0 = W // 2 - bw // 2, 1500 - bh // 2
        d.rounded_rectangle((x0, y0, x0 + bw, y0 + bh), bh // 2, fill=ORANGE)
        if a > 0.7:
            f = font(46, "Heavy")
            txt = "Ссылка в профиле"
            d.text((W // 2 - f.getlength(txt) / 2, 1500 - 30), txt, font=f, fill=(20, 12, 0))

def frame_at(t):
    k, lt, dur = scene_at(t)
    # background drift
    ox = int(100 + 80 * math.sin(t * 0.35))
    oy = int(100 + 80 * math.cos(t * 0.27))
    frame = BG.crop((ox, oy, ox + W, oy + H)).convert("RGBA")
    # display intro zoom
    intro = ease_out(t / 0.7)
    disp = DISPLAY
    if intro < 1:
        s = 1.12 - 0.12 * intro
        disp = fade(DISPLAY.resize((int(DISPLAY.width * s), int(DISPLAY.height * s)), Image.BICUBIC), intro)
        frame.alpha_composite(disp, (W // 2 - disp.width // 2, DY - int((s - 1) * 200)))
    else:
        frame.alpha_composite(disp, (DX, DY))
    # dim the display for the end card
    if k == 7:
        a = ease_io((lt - 0.3) / 0.5)
        dim = Image.new("RGBA", (DW, DH), (5, 5, 10, int(170 * a)))
        frame.alpha_composite(dim, (DX + 14, DY + 14))
    # panel + glow
    layer, px, py = panel_layer(t)
    if layer.width > 300:
        g = GLOW.resize((layer.width + 160, layer.height + 140))
        glow = Image.new("RGBA", g.size, (140, 110, 255, 0))
        glow.putalpha(g.point(lambda v: v * 70 // 255))
        frame.alpha_composite(glow, (px - 80, py - 40))
    frame.alpha_composite(layer, (px, py))
    # hook: pulsing rings around the notch
    if t < 4.0 and t > 0.9:
        d = ImageDraw.Draw(frame)
        cx, cy = W // 2, DY + 14 + NOTCH_H // 2
        for j in range(3):
            p = ((t - 0.9) * 0.9 + j / 3) % 1
            r = 60 + p * 220
            col = (*ORANGE, int(230 * (1 - p)))
            ring = Image.new("RGBA", (W, 700), (0, 0, 0, 0))
            ImageDraw.Draw(ring).ellipse((cx - r * 1.4, 100 - r * 0.6, cx + r * 1.4, 100 + r * 0.6), outline=col, width=5)
            frame.alpha_composite(ring.crop((0, 100 - NOTCH_H // 2, W, 700)), (0, cy - NOTCH_H // 2))
    # cursor: glides to the notch, hovers, then leaves
    if 3.1 <= t < 5.4:
        if t < 4.0:
            k2 = ease_io((t - 3.1) / 0.9)
            cx, cy = lerp(820, W // 2 + 6, k2), lerp(1000, DY + 30, k2)
        else:
            k2 = ease_io((t - 4.6) / 0.8)
            cx, cy = lerp(W // 2 + 6, W // 2 + 6, k2), lerp(DY + 30, DY + 30 + 0, k2)
            cx += 400 * k2
        frame.alpha_composite(CURSOR, (int(cx), int(cy)))
    # headline
    if k == 7:
        end_card(frame, lt)
    elif HEADS[k]:
        y = DY + DH + 80
        out = ease_io((lt - (dur - 0.25)) / 0.25)
        for j, im in enumerate(HEADS[k]):
            a = ease_out((lt - 0.1 - j * 0.1) / 0.4) * (1 - out)
            if a > 0:
                frame.alpha_composite(fade(im, a), (W // 2 - im.width // 2, y + int(50 * (1 - a))))
            y += 112
    # top label
    d = ImageDraw.Draw(frame)
    f = font(30, "Bold")
    lab = "NOTCHMATE  ·  ДЛЯ MACBOOK"
    d.text((W // 2 - f.getlength(lab) / 2, 225), lab, font=f, fill=(255, 255, 255, 150))
    return frame.convert("RGB")

if PREVIEW:
    for s in PREVIEW:
        frame_at(float(s)).save(OUT.parent / f"prev_{s}.png")
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
