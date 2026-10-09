"""Writes jobs.json: one job per picture (a background and a badge for each rank), the same way
Bùbù's art is batched. Edit the ranks or the style here, then run `python make_jobs.py`.

Jobs are in two groups:
- "test": Dumpling only, to check the style before making the rest;
- "ranks": the other five, which attach the approved Dumpling pictures as style references.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

STYLE_BG = """Art for a calorie-tracking iPhone app called Cheat Days. It has six ranks like game leagues, each named after a food: Crumb, Toast, Dumpling, Burger, Feast, Legend. This is one rank's background, in the style of a Valorant rank-up screen or a Duolingo league banner. It sits behind a dark panel with a big white calorie number on the left.

Style:
- Wide landscape, 3:2.
- Abstract, not an illustration of food: a very dark base (deep navy to black, around #0b1520) with glowing energy in the rank's accent colour: sweeping light streaks, angular crystal shards or geometric facets, soft volumetric glow, a few floating particles. Clean, sleek and premium, like an esports or mobile game rank screen.
- The rank's symbol (given below) appears once as a large, faint, glowing silhouette on the right, partly fading into the dark: a watermark, not a detailed drawing.
- The left 55% stays almost empty and dark, with only faint wisps of light reaching in. The energy and the silhouette sit on the right.
- Big white text on top must stay easy to read: keep it dark overall, with the glow concentrated on the right.
- Higher ranks get more intense: more streaks and shards, brighter glow. The first rank is the calmest.
- No text, letters, numbers, logos, UI, people or realistic food. Nothing awkwardly cut off at the right edge."""

STYLE_BADGE = """Art for a calorie-tracking iPhone app called Cheat Days. It has six ranks like game leagues (Duolingo leagues, Valorant ranks), each named after a food: Crumb, Toast, Dumpling, Burger, Feast, Legend. This is one rank's badge, shown small (about 50 points wide) on a dark panel.

Style:
- Square. The badge centred, filling about 85% of the canvas.
- A shield or crest shape like a game rank emblem. Flat, modern, gently glowing, like a mobile game.
- One accent colour, given below, with a darker body in the same hue. Higher ranks get fancier frames.
- A simple symbol in the middle that still reads when tiny.
- Background: a flat, solid, pure magenta (#FF00FF) filling the whole canvas, with no shadow, gradient or glow on it, so it can be cut out. Don't use magenta or pink anywhere in the badge itself.
- No text, letters or numbers."""

REF_NOTE = "The attached image is this app's Dumpling rank art: match their style, lighting, darkness and level of detail exactly. Don't copy its symbol or colour; use only what's described below.\n\n"

RANKS = [
    ("crumb", "Crumb", "the very first rank", "warm bronze (#c9965c)",
     "calm: two or three dim bronze light streaks, a few small floating shards; symbol silhouette: a biscuit with a bite out of it",
     "a plain bronze shield with a single small biscuit symbol: the simplest badge of the set"),
    ("toast", "Toast", "the second rank", "steel silver-blue (#9fb8d0)",
     "a little more energy: silver-blue light streaks crossing, a few angular shards; symbol silhouette: a slice of toast",
     "a silver shield with a slice of toast, a step fancier than Crumb (a simple trim round the edge)"),
    ("dumpling", "Dumpling", "the third rank", "jade teal (#5dcaa5)",
     "teal energy swirling upwards like stylised steam, sleek streaks and crystal facets; symbol silhouette: a dumpling",
     "a teal shield with a dumpling symbol and a neat double trim"),
    ("burger", "Burger", "the fourth rank", "ember orange-red (#f0784b)",
     "fiery: ember-orange streaks and sparks rushing upwards, sharper shards; symbol silhouette: a burger",
     "an orange-red crest with small wings at the sides and a burger symbol, clearly fancier than Dumpling"),
    ("feast", "Feast", "the fifth rank", "royal violet (#9d8cf0)",
     "rich: violet light ribbons and faceted crystals, a soft radial burst; symbol silhouette: a covered serving dish (cloche)",
     "a violet crest with a laurel wreath and a covered serving dish (cloche) symbol, ornate"),
    ("legend", "Legend", "the very top rank", "radiant gold (#fac775)",
     "the most epic: radiant gold light rays bursting from behind, many golden shards and sparkles; symbol silhouette: a pizza slice with a small crown",
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
