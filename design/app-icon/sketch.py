"""Draws sketch.png: the approved layout (the week as a ring of seven segments; the cheat day's segment is a whole pizza slice), as a
reference for the image generator. Not the final art: the generator makes the smooth version."""
import math
from PIL import Image, ImageDraw

N = 1024
SS = 3                      # drawn 3x and scaled down, for smooth edges
W = N * SS
img = Image.new("RGB", (W, W))
d = ImageDraw.Draw(img)
for y in range(W):          # navy, a touch lighter at the top
    t = y / W
    d.line([(0, y), (W, y)], fill=(int(28 + (14 - 28) * t), int(48 + (26 - 48) * t), int(82 + (46 - 82) * t)))

s = W / 184                 # the mock-up was 184 units square
c, cy = 92 * s, 93 * s
R, r = 62 * s, 34 * s
step = 360 / 7

def pt(rad, deg, ox=0.0, oy=0.0):
    a = math.radians(deg)
    return (c + ox + rad * math.sin(a), cy + oy - rad * math.cos(a))

def arc(rad, a0, a1, ox=0.0, oy=0.0, n=60):
    return [pt(rad, a0 + (a1 - a0) * i / n, ox, oy) for i in range(n + 1)]

# the week: six ring segments with small gaps
for i in range(1, 7):
    a0 = -step / 2 + i * step + 3
    a1 = a0 + step - 6
    d.polygon(arc(R, a0, a1) + arc(r, a1, a0), fill=(220, 234, 247))

# the cheat day: the seventh segment is a whole pizza slice, tip at the centre, nudged out a little
lift = -6 * s
a0, a1 = -step / 2 + 3, step / 2 - 3
d.polygon([(c, cy + lift)] + arc(R, a0, a1, 0, lift), fill=(244, 183, 64))
d.polygon(arc(R + 1 * s, a0 + 0.4, a1 - 0.4, 0, lift) + arc(R - 9 * s, a1 - 0.4, a0 + 0.4, 0, lift), fill=(217, 134, 47))
for a, rad, pr in [(-8, R - 21 * s, 5), (9, R - 31 * s, 4), (-1, R - 43 * s, 3.2)]:
    x, y = pt(rad, a, 0, lift)
    d.ellipse([x - pr * s, y - pr * s, x + pr * s, y + pr * s], fill=(207, 71, 51))

img.resize((N, N), Image.LANCZOS).save("sketch.png")
print("sketch.png")
