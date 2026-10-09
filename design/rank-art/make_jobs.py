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
- Anime / cartoon style: cel-shaded with clean, confident line art, bold simple shapes and two or three flat shading tones, like a Studio Ghibli food scene or a Japanese mobile game rank screen. Chunky, appealing, slightly exaggerated food that looks delicious, with anime-style sparkles, glossy highlights and stylised steam or light. Not painterly, not realistic.
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
     "a few golden biscuit crumbs and a half-eaten biscuit scattered on the right, softly lit in bronze, humble and simple",
     "a plain bronze shield with a single small biscuit symbol: the simplest badge of the set"),
    ("toast", "Toast", "the second rank", "steel silver-blue (#9fb8d0)",
     "two slices of toast popping out of a sleek toaster on the right, a little butter melting, cool silver rim light",
     "a silver shield with a slice of toast, a step fancier than Crumb (a simple trim round the edge)"),
    ("dumpling", "Dumpling", "the third rank", "jade teal (#5dcaa5)",
     "a stack of bamboo steamer baskets with a few dumplings peeking out and soft steam curling up, on the right, lit in teal",
     "a teal shield with a dumpling symbol and a neat double trim"),
    ("burger", "Burger", "the fourth rank", "ember orange-red (#f0784b)",
     "a tall stacked burger on the right with glowing ember sparks drifting up, warm orange light, a little heat haze",
     "an orange-red crest with small wings at the sides and a burger symbol, clearly fancier than Dumpling"),
    ("feast", "Feast", "the fifth rank", "royal violet (#9d8cf0)",
     "a long banquet table on the right with a roast, a cake and goblets, candles glowing violet, rich and celebratory",
     "a violet crest with a laurel wreath and a covered serving dish (cloche) symbol, ornate"),
    ("legend", "Legend", "the very top rank", "radiant gold (#fac775)",
     "a glowing golden pizza slice floating on the right with a crown above it, gold sparkles and soft light rays, epic but still dark overall",
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
