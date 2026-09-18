"""Draws the app icon: a pie with one slice taken out. Run once: python make_icons.py"""
from PIL import Image, ImageDraw

def icon(size):
    s = size * 4  # draw big, shrink for smooth edges
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, s, s), radius=s * 0.22, fill=(47, 93, 75))
    pad = s * 0.18
    box = (pad, pad, s - pad, s - pad)
    d.pieslice(box, 300, 240, fill=(216, 234, 217))          # the whole pie...
    d.pieslice(box, 240, 300, fill=(224, 138, 60))           # ...and the slice you're spending
    hole = s * 0.31
    d.ellipse((hole, hole, s - hole, s - hole), fill=(47, 93, 75))
    return im.resize((size, size), Image.LANCZOS)

for n in (180, 192, 512):
    icon(n).save(f"icons/icon-{n}.png")
print("icons written")
