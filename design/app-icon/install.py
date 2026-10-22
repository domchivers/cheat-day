"""Puts the finished icon (icon.png, 1024 x 1024) into the iPhone app and the website, and writes review.html.
Run from design/app-icon:  python install.py"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
src = Image.open(os.path.join(HERE, "icon.png")).convert("RGB")
if src.size[0] != src.size[1]:
    side = min(src.size)
    l, t = (src.size[0] - side) // 2, (src.size[1] - side) // 2
    src = src.crop((l, t, l + side, t + side))
big = src.resize((1024, 1024), Image.LANCZOS)

# iPhone: one 1024 square, no transparency (iOS rounds the corners itself)
big.save(os.path.join(ROOT, "native", "CheatDays", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"))

# website: rounded like the old ones, so they look right as a favicon and on Android
def rounded(size):
    im = big.resize((size, size), Image.LANCZOS).convert("RGBA")
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * 0.225), fill=255)
    im.putalpha(m.resize((size, size), Image.LANCZOS))
    return im
for size in (180, 192, 512):
    out = big.resize((size, size), Image.LANCZOS) if size == 180 else rounded(size)   # 180 is Apple's touch icon: square
    out.save(os.path.join(ROOT, "icons", f"icon-{size}.png"))

with open(os.path.join(HERE, "review.html"), "w", encoding="utf-8") as f:
    f.write("""<!doctype html><meta charset="utf-8"><title>Cheat Days icon</title>
<body style="background:#111;color:#ddd;font-family:system-ui;padding:30px">
<h2>New icon</h2><img src="icon.png" width="320" style="border-radius:72px">
<h3>Home-screen sizes</h3>
<img src="icon.png" width="120" style="border-radius:27px;margin-right:20px"><img src="icon.png" width="60" style="border-radius:13px;margin-right:20px"><img src="icon.png" width="40" style="border-radius:9px">
<h3>The sketch it came from</h3><img src="sketch.png" width="200" style="border-radius:45px"></body>""")
print("installed: AppIcon 1024, icons/icon-180/192/512.png; open design/app-icon/review.html")
