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
# the movement drawn over each picture (the same settings go into the app): kind, colour, light source
FX = {
    "crumb": ("dust", "201,150,92", 0.74, 0.62),
    "toast": ("heat", "159,184,208", 0.76, 0.42),
    "dumpling": ("steam", "93,202,165", 0.77, 0.40),
    "burger": ("embers", "240,120,75", 0.76, 0.50),
    "feast": ("candles", "157,140,240", 0.75, 0.45),
    "legend": ("sparkle", "250,199,117", 0.78, 0.38),
}
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


SCRIPT = """<script>
// Movement over each rank's picture: a pulsing glow at the light source, motes drifting up, and the rank's own effect.
const rnd = (a, b) => a + Math.random() * (b - a);
for (const hero of document.querySelectorAll('.hero')) {
  const cv = hero.querySelector('canvas'), g = cv.getContext('2d');
  const kind = hero.dataset.fx, c = hero.dataset.c, sx = +hero.dataset.x, sy = +hero.dataset.y;
  let W = 0, H = 0, parts = [], t0 = performance.now();
  const size = () => { const r = devicePixelRatio || 1; W = hero.clientWidth; H = hero.clientHeight; cv.width = W * r; cv.height = H * r; g.setTransform(r, 0, 0, r, 0, 0); };
  size(); addEventListener('resize', size);
  const spawn = () => {
    const x = sx * W, y = sy * H;
    if (kind === 'steam') return { k: 'puff', x: x + rnd(-14, 14), y: y + rnd(-4, 6), vx: rnd(-.08, .08), vy: rnd(-.32, -.2), r: rnd(12, 22), gr: rnd(.07, .12), life: 0, max: rnd(260, 380), w: rnd(0, 6.28) };
    if (kind === 'embers') return { k: 'dot', x: x + rnd(-30, 30), y: y + rnd(-6, 12), vx: rnd(-.25, .25), vy: rnd(-1.1, -.5), r: rnd(1, 2.2), life: 0, max: rnd(90, 170), w: rnd(0, 6.28), flick: true };
    if (kind === 'sparkle') return { k: 'star', x: rnd(.55, .98) * W, y: rnd(.08, .9) * H, r: rnd(2, 5), life: 0, max: rnd(70, 140) };
    if (kind === 'candles') return { k: 'dot', x: x + rnd(-60, 50), y: y + rnd(-20, 20), vx: rnd(-.05, .05), vy: rnd(-.35, -.15), r: rnd(.8, 1.8), life: 0, max: rnd(140, 240), w: rnd(0, 6.28) };
    if (kind === 'heat') return { k: 'wave', x: x + rnd(-24, 24), y: y + rnd(0, 10), vy: rnd(-.45, -.3), life: 0, max: rnd(120, 180), w: rnd(0, 6.28) };
    return { k: 'dot', x: rnd(.55, .98) * W, y: rnd(.05, .6) * H, vx: rnd(-.06, .06), vy: rnd(.05, .16), r: rnd(.8, 1.6), life: 0, max: rnd(260, 400), w: rnd(0, 6.28) };   // dust settling
  };
  const mote = () => ({ k: 'dot', x: rnd(.5, 1) * W, y: H + 4, vx: rnd(-.05, .05), vy: rnd(-.22, -.1), r: rnd(.6, 1.3), life: 0, max: rnd(500, 800), w: rnd(0, 6.28) });
  const rate = { steam: .24, embers: .35, sparkle: .06, candles: .12, heat: .1, dust: .05 }[kind] || .05;
  const frame = (now) => {
    const t = (now - t0) / 1000;
    g.clearRect(0, 0, W, H);
    // the glow at the light source, breathing (candles flicker instead)
    const pulse = kind === 'candles' ? .16 + .05 * Math.sin(t * 9) * Math.sin(t * 3.7) : .14 + .07 * Math.sin(t * 1.6);
    const rg = g.createRadialGradient(sx * W, sy * H, 0, sx * W, sy * H, H * .75);
    rg.addColorStop(0, `rgba(${c},${pulse})`); rg.addColorStop(1, `rgba(${c},0)`);
    g.fillStyle = rg; g.fillRect(0, 0, W, H);
    if (kind === 'sparkle') {   // slow light rays turning behind the crown
      g.save(); g.translate(sx * W, sy * H); g.rotate(t * .06);
      for (let i = 0; i < 8; i++) { g.rotate(Math.PI / 4); g.fillStyle = `rgba(${c},.045)`; g.beginPath(); g.moveTo(0, 0); g.lineTo(H * 1.2, -14); g.lineTo(H * 1.2, 14); g.fill(); }
      g.restore();
    }
    if (Math.random() < rate) parts.push(spawn());
    if (Math.random() < .05) parts.push(mote());
    parts = parts.filter((p) => p.life < p.max);
    for (const p of parts) {
      p.life++; const k = p.life / p.max, fade = Math.sin(Math.PI * k);
      if (p.k === 'puff') {
        p.x += p.vx + Math.sin(t * 1.3 + p.w) * .25; p.y += p.vy; p.r += p.gr;
        const pg = g.createRadialGradient(p.x, p.y, 0, p.x, p.y, p.r);
        pg.addColorStop(0, `rgba(${c},${.28 * fade})`); pg.addColorStop(1, `rgba(${c},0)`);
        g.fillStyle = pg; g.beginPath(); g.arc(p.x, p.y, p.r, 0, 6.29); g.fill();
      } else if (p.k === 'star') {
        const a = fade, r = p.r * (.6 + .4 * fade);
        g.fillStyle = `rgba(255,240,200,${a})`; g.beginPath();
        g.moveTo(p.x, p.y - r * 2); g.quadraticCurveTo(p.x, p.y, p.x + r * 2, p.y); g.quadraticCurveTo(p.x, p.y, p.x, p.y + r * 2); g.quadraticCurveTo(p.x, p.y, p.x - r * 2, p.y); g.quadraticCurveTo(p.x, p.y, p.x, p.y - r * 2); g.fill();
      } else if (p.k === 'wave') {
        p.y += p.vy; g.strokeStyle = `rgba(${c},${.12 * fade})`; g.lineWidth = 1.2; g.beginPath();
        for (let i = 0; i <= 10; i++) { const yy = p.y - i * 2.5; g.lineTo(p.x + Math.sin(i * .8 + t * 3 + p.w) * 3, yy); } g.stroke();
      } else {
        p.x += p.vx + Math.sin(t + p.w) * .08; p.y += p.vy;
        const a = (p.flick ? .5 + .5 * Math.sin(t * 20 + p.w) : 1) * fade * .9;
        g.fillStyle = `rgba(${c},${a})`; g.shadowColor = `rgba(${c},.9)`; g.shadowBlur = 6;
        g.beginPath(); g.arc(p.x, p.y, p.r, 0, 6.29); g.fill(); g.shadowBlur = 0;
      }
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}
</script>"""


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
 <div class="hero" data-fx="{FX[key][0]}" data-c="{FX[key][1]}" data-x="{FX[key][2]}" data-y="{FX[key][3]}">
  <div class="art" style="{'background-image:url(' + bg + ')' if bg else ''}"></div><canvas></canvas>
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
.art{position:absolute;inset:0;background:center/cover;animation:drift 18s ease-in-out infinite alternate}
@keyframes drift{from{transform:scale(1.0) translate(0,0)}to{transform:scale(1.07) translate(-1.5%,-1%)}}
canvas{position:absolute;inset:0;width:100%;height:100%;pointer-events:none}
.l,.n,.bar,.st,.badge{position:relative;z-index:2}.badge{position:absolute}
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
<div class="grid">""" + "".join(cards) + "</div>" + SCRIPT
    with open(os.path.join(HERE, "out", "review.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote out/review.html")
    for key, note in rows:
        print(f"  {key}: {'; '.join(note) or 'ok'}")


if __name__ == "__main__":
    main()
