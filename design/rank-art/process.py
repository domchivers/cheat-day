"""Turns out/raw/*.png into app-ready art in out/final/, then writes out/review.html.

- Badges: the magenta backdrop is keyed out (soft edges despilled) and the badge trimmed and
  squared to 512 x 512.
- Backgrounds: cropped to 3:2, scaled to 1200 x 800, and darkened only if the left side
  (where the calorie number goes) is too bright to read white text on.

out/review.html shows each rank as it would look on Today, with "564 kcal" and the badge on
top, so readability and style can be judged at a glance.

    python process.py
"""
import glob
import os

import numpy as np
from PIL import Image, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "out", "raw")
FINAL = os.path.join(HERE, "out", "final")
ORDER = ["crumb", "toast", "dumpling", "burger", "feast", "legend"]
NAMES = {"crumb": "Crumb", "toast": "Toast", "dumpling": "Dumpling", "burger": "Burger", "feast": "Feast", "legend": "Legend"}


def key_badge(im):
    rgba = np.asarray(im.convert("RGBA"))
    if rgba[..., 3].min() < 255:            # already transparent
        out = Image.fromarray(rgba, "RGBA")
    else:
        a = rgba[..., :3].astype(np.float32)
        k = 12
        bg = np.median(np.concatenate([a[:k, :k].reshape(-1, 3), a[:k, -k:].reshape(-1, 3), a[-k:, :k].reshape(-1, 3), a[-k:, -k:].reshape(-1, 3)]), axis=0)
        if np.abs(bg - np.array([255, 0, 255])).max() < 60:
            m = np.minimum(a[..., 0], a[..., 2]) - a[..., 1]     # 'magenta-ness'
            alpha = 1 - np.clip((m - 60) / (190 - 60), 0, 1)
        else:
            d = np.sqrt(((a - bg) ** 2).sum(axis=2))
            alpha = np.clip((d - 22) / (62 - 22), 0, 1)
        edge = (alpha > 0) & (alpha < 1)
        fg = a.copy()
        fg[edge] = (a[edge] - (1 - alpha[edge, None]) * bg) / np.maximum(alpha[edge, None], 0.05)
        out = Image.fromarray(np.dstack([fg, alpha * 255]).clip(0, 255).astype(np.uint8), "RGBA")
    box = out.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if box:
        out = out.crop(box)
    side = max(out.size)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(out, ((side - out.width) // 2, (side - out.height) // 2))
    return sq.resize((512, 512), Image.LANCZOS)


def fit_bg(im):
    im = im.convert("RGB")
    w, h = im.size
    if w / h > 1.5:
        nw = int(h * 1.5); im = im.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
    elif w / h < 1.5:
        nh = int(w / 1.5); im = im.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    im = im.resize((1200, 800), Image.LANCZOS)
    # the number sits on the left: keep that part dark enough for white text
    left = np.asarray(im.crop((0, 0, 660, 800)).convert("L")).astype(np.float32)
    bright = float(np.percentile(left, 90))
    note = ""
    if bright > 70:
        im = ImageEnhance.Brightness(im).enhance(70 / bright)
        note = f"darkened (left side was {bright:.0f}/255)"
    return im, note


def main():
    os.makedirs(FINAL, exist_ok=True)
    rows = []
    for key in ORDER:
        bg_src, badge_src = os.path.join(RAW, f"{key}-bg.png"), os.path.join(RAW, f"{key}-badge.png")
        note = []
        if os.path.exists(bg_src):
            bg, n = fit_bg(Image.open(bg_src))
            bg.save(os.path.join(FINAL, f"rank-{key}-bg.jpg"), quality=86)
            if n: note.append(n)
        else:
            note.append("background missing")
        if os.path.exists(badge_src):
            key_badge(Image.open(badge_src)).save(os.path.join(FINAL, f"rank-{key}-badge.png"))
        else:
            note.append("badge missing")
        rows.append((key, note))
    cards = []
    for key, note in rows:
        bg = f"final/rank-{key}-bg.jpg" if os.path.exists(os.path.join(FINAL, f"rank-{key}-bg.jpg")) else ""
        badge = f"final/rank-{key}-badge.png" if os.path.exists(os.path.join(FINAL, f"rank-{key}-badge.png")) else ""
        cards.append(f"""
<div class="item"><h2>{NAMES[key]}</h2>
 <div class="hero" style="{'background-image:url(' + bg + ')' if bg else ''}">
  <div class="l">LEFT TO EAT</div><div class="n">564 <small>kcal</small></div>
  {'<img class="badge" src="' + badge + '">' if badge else ''}
  <div class="bar"><i style="width:22%;background:#fac775"></i><i style="width:30%;background:#5dd19e"></i></div>
  <div class="st"><span>1,086 eaten</span><span>55 / 140g</span><span>1,650</span></div>
 </div>
 <div class="raw">{'<img src="' + badge + '" class="big">' if badge else ''}</div>
 <p>{'; '.join(note) or 'ok'}</p></div>""")
    html = """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rank art review</title>
<style>
body{background:#07090c;color:#eef3f8;font-family:-apple-system,system-ui,sans-serif;margin:0;padding:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:24px}
h2{font-size:18px;margin:0 0 8px}
.hero{position:relative;border-radius:22px;padding:18px;height:190px;background:#0f1a26 center/cover;overflow:hidden}
.l{font-size:12px;letter-spacing:.08em;color:#8fbadd;font-weight:700}
.n{font-size:62px;font-weight:800;line-height:1.05}.n small{font-size:17px;color:#93a1ae}
.badge{position:absolute;right:18px;top:58px;width:58px;height:58px}
.bar{display:flex;gap:2px;height:11px;border-radius:6px;overflow:hidden;background:#1c2b3a;margin:12px 0 10px}
.st{display:flex;justify-content:space-between;color:#cfd8e0;font-size:13px;font-weight:700}
.raw{background:repeating-conic-gradient(#222 0 25%,#333 0 50%) 0 0/20px 20px;border-radius:12px;margin-top:10px;padding:10px;text-align:center}
.big{width:160px}
p{color:#93a1ae;font-size:13px}
</style>
<h1>Rank art</h1><p>Each rank as it would sit behind the calorie panel on Today. Check the number is easy to read, the badge reads small, and there's no text or pink in the art.</p>
<div class="grid">""" + "".join(cards) + "</div>"
    with open(os.path.join(HERE, "out", "review.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote out/review.html")
    for key, note in rows:
        print(f"  {key}: {'; '.join(note) or 'ok'}")


if __name__ == "__main__":
    main()
