"""Writes jobs.json: one job per picture (a background and a badge for each rank), the same way
Bùbù's art is batched. Edit the ranks or the style here, then run `python make_jobs.py`.

Jobs are in two groups:
- "test": Dumpling only, to check the style before making the rest;
- "ranks": the other five, which attach the approved Dumpling pictures as style references.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

STYLE_BG = """Art for a calorie-tracking iPhone app called Cheat Days. It has six ranks like game leagues (Duolingo leagues, Valorant ranks), each named after a food: Crumb, Toast, Dumpling, Burger, Feast, Legend. This is one rank's background. It sits behind a dark panel with a big white calorie number on the left.

Style:
- Wide landscape, 3:2.
- Very dark overall: a deep navy-to-black base (around #0b1520), like a night-mode game menu. Big white text on top must stay easy to read.
- The left 55% stays almost empty: just the dark base with very faint texture. All the detail sits on the right and fades out towards the left.
- Simple cartoon / anime style, like a sticker or a Duolingo illustration: big, bold, rounded shapes with clean outlines and flat colour fills, at most one soft shading tone per shape. Cute and chunky, slightly exaggerated proportions.
- Keep it VERY SIMPLE: only the main subject (one object or a small group of two or three) and a few stylised swirls or sparkles. No background scenery (no plants, lanterns, tables, walls or extra props), no texture, no grain, no fine detail, no wood grain or weave patterns, no small repeated details. The rest is plain dark base with lots of empty space.
- One accent colour, given below, used for the glow and highlights.
- No text, letters, numbers, logos, UI or people. Nothing awkwardly cut off at the right edge."""

STYLE_BADGE = """Art for a calorie-tracking iPhone app called Cheat Days. It has six ranks like game leagues (Duolingo leagues, Valorant ranks), each named after a food: Crumb, Toast, Dumpling, Burger, Feast, Legend. This is one rank's badge, shown small (about 50 points wide) on a dark panel.

Style:
- Square. The badge centred, filling about 85% of the canvas.
- A shield or crest shape like a game rank emblem. Flat, modern, gently glowing, like a mobile game.
- One accent colour, given below, with a darker body in the same hue. Higher ranks get fancier frames.
- A simple symbol in the middle that still reads when tiny.
- Background: a flat, solid, pure magenta (#FF00FF) filling the whole canvas, with no shadow, gradient or glow on it, so it can be cut out. Don't use magenta or pink anywhere in the badge itself.
- No text, letters or numbers."""

REF_NOTE = "The attached image is this app's Dumpling rank art: match their style, lighting, darkness and level of detail exactly. Don't copy their subject; draw only what's described below.\n\n"

RANKS = [
    ("crumb", "Crumb", "the very first rank", "warm bronze (#c9965c)",
     "one cartoon biscuit with a bite out of it and three or four crumbs, on the right, softly lit in bronze",
     "a plain bronze shield with a single small biscuit symbol: the simplest badge of the set"),
    ("toast", "Toast", "the second rank", "steel silver-blue (#9fb8d0)",
     "one chunky cartoon toaster with two slices of toast popping up and a pat of butter, on the right, cool silver light",
     "a silver shield with a slice of toast, a step fancier than Crumb (a simple trim round the edge)"),
    ("dumpling", "Dumpling", "the third rank", "jade teal (#5dcaa5)",
     "one round bamboo steamer, lid off, with three plump cartoon dumplings in it and two or three simple curly steam swirls rising, on the right, lit in teal",
     "a teal shield with a dumpling symbol and a neat double trim"),
    ("burger", "Burger", "the fourth rank", "ember orange-red (#f0784b)",
     "one tall, chunky cartoon burger with a few simple ember sparks above it, on the right, warm orange light",
     "an orange-red crest with small wings at the sides and a burger symbol, clearly fancier than Dumpling"),
    ("feast", "Feast", "the fifth rank", "royal violet (#9d8cf0)",
     "a cartoon roast chicken on a plate next to a small cake with one candle, on the right, violet candle glow",
     "a violet crest with a laurel wreath and a covered serving dish (cloche) symbol, ornate"),
    ("legend", "Legend", "the very top rank", "radiant gold (#fac775)",
     "one glowing cartoon pizza slice with a little crown above it and a few gold sparkles, on the right, simple light rays behind",
     "the most elaborate badge: a gold crest with wings, a crown on top and a pizza slice symbol, gently glowing"),
]


def main():
    jobs = []
    for key, name, place, accent, scene, badge in RANKS:
        test = key == "dumpling"
        bg_refs = [] if test else ["out/raw/dumpling-bg.png"]          # backgrounds match the approved background,
        badge_refs = [] if test else ["out/raw/dumpling-badge.png"]    # badges match the approved badge
        lead = "" if test else REF_NOTE
        jobs.append({"file": f"out/raw/{key}-bg.png", "group": "test" if test else "ranks", "size": "1536x1024", "refs": bg_refs,
                     "prompt": f"{lead}{STYLE_BG}\n\nRank: {name}, {place}. Accent colour: {accent}.\nScene: {scene}."})
        jobs.append({"file": f"out/raw/{key}-badge.png", "group": "test" if test else "ranks", "size": "1024x1024", "refs": badge_refs,
                     "prompt": f"{lead}{STYLE_BADGE}\n\nRank: {name}, {place}. Accent colour: {accent}.\nBadge: {badge}."})
    jobs.sort(key=lambda j: j["group"] != "test")   # the test first
    with open(os.path.join(HERE, "jobs.json"), "w", encoding="utf-8") as f:
        json.dump(jobs, f, indent=1, ensure_ascii=False)
    print(f"{len(jobs)} jobs written")


if __name__ == "__main__":
    main()
