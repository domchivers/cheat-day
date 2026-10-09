# Rank art for Cheat Days: ChatGPT prompts

> **Batching with Codex (like Bùbù):** give Codex `design/rank-art/CODEX.md`. It works through `jobs.json`: Dumpling first as a test, then the other five once you approve. Then `process.py` cuts out the badges and writes `out/review.html`. The prompts below are the same thing by hand, for pasting into ChatGPT one at a time.

The art goes behind the calorie panel on Today, with each rank's badge on top. Make **one test picture first** (step 1). If you like it, use the same chat for the rest (step 2), so ChatGPT keeps the style.

Save every picture into this folder (`design/rank-art/`) using the file name given for it. I'll do the rest: trim, darken if needed, and add them to the app.

---

## Step 1: one test (copy everything in the box)

```
I'm making art for a calorie-tracking iPhone app called Cheat Days. It has six ranks, like game leagues (Duolingo leagues, Valorant ranks), each named after a food: Crumb, Toast, Dumpling, Burger, Feast, Legend. Each rank needs a wide background image that sits behind a dark panel showing a big white calorie number on the left.

Please make the background for the rank "Dumpling".

Style rules (keep these for every rank I ask for later):
- Wide landscape, 3:2, around 1536 x 1024.
- Very dark overall: a deep navy-to-black base (around #0b1520), like a night-mode game menu. It must stay dark enough for big white text to be easy to read on top.
- The left 55% stays almost empty: just the dark base with very faint texture. All the detail sits on the right side and fades out towards the left.
- Flat, modern, slightly glowing illustration style, like a mobile game rank screen. Soft rim light, gentle bloom, no harsh contrast.
- One accent colour per rank. For Dumpling, use jade/teal (#5dcaa5) glow highlights.
- Subject for Dumpling: a stack of bamboo steamer baskets with a few dumplings peeking out and soft steam curling up, on the right side, lit by teal light.
- No text, no letters, no numbers, no logos, no UI, no people.
- Clean edges, nothing cut off awkwardly at the right edge.
```

Then in the same chat, ask for the badge:

```
Now make the rank badge for "Dumpling" to go with it.
- Square, 1024 x 1024, on a fully transparent background (PNG).
- A shield or crest shape like a game rank emblem, centred, filling about 85% of the canvas.
- Same style as the background: flat, gently glowing, jade/teal accent (#5dcaa5) with a darker teal body.
- A simple dumpling symbol in the middle, readable even when shown tiny (about 50 pixels wide).
- No text, letters or numbers.
```

Save them as:
- `dumpling-bg.png`
- `dumpling-badge.png`

Send me both. If they look right in the app, carry on with step 2.

---

## Step 2: the rest (same chat, one message per rank)

Each message makes the background and then the badge. If ChatGPT only makes one picture, reply "now the badge". Keep the style rules from step 1. If a picture comes out too bright, reply: "Same picture, but much darker, and keep the left side empty."

### Crumb (the first rank)
```
Same style rules as before. Rank "Crumb", the very first rank. Accent: warm bronze (#c9965c).
Background subject: a few golden biscuit crumbs and a half-eaten biscuit scattered on the right, lit softly in bronze, humble and simple.
Then the badge: a plain bronze shield with a single crumb or small biscuit symbol, the simplest badge of the set.
```
Save as `crumb-bg.png` and `crumb-badge.png`.

### Toast
```
Same style rules as before. Rank "Toast". Accent: steel silver-blue (#9fb8d0).
Background subject: two slices of toast popping out of a sleek toaster on the right, a little butter melting, cool silver rim light.
Then the badge: a silver shield with a slice of toast symbol, a step fancier than Crumb (a simple trim around the edge).
```
Save as `toast-bg.png` and `toast-badge.png`.

### Burger
```
Same style rules as before. Rank "Burger". Accent: ember orange-red (#f0784b).
Background subject: a tall stacked burger on the right with glowing ember sparks drifting up, warm orange light, a bit of heat haze.
Then the badge: an orange-red crest with small wings at the sides and a burger symbol, clearly fancier than Dumpling.
```
Save as `burger-bg.png` and `burger-badge.png`.

### Feast
```
Same style rules as before. Rank "Feast". Accent: royal violet (#9d8cf0).
Background subject: a long banquet table on the right with a roast, a cake and goblets, candles glowing violet, rich and celebratory.
Then the badge: a violet crest with a laurel wreath and a covered serving dish (cloche) symbol, ornate.
```
Save as `feast-bg.png` and `feast-badge.png`.

### Legend (the top rank)
```
Same style rules as before. Rank "Legend", the very top rank. Accent: radiant gold (#fac775).
Background subject: a glowing golden pizza slice floating on the right with a crown above it, gold sparkles and soft light rays, epic but still dark overall.
Then the badge: the most elaborate one, a gold crest with wings, a crown on top and a pizza slice symbol, with a gentle glow.
```
Save as `legend-bg.png` and `legend-badge.png`.

---

## Checklist

| Rank | Background | Badge |
|---|---|---|
| Crumb | `crumb-bg.png` | `crumb-badge.png` |
| Toast | `toast-bg.png` | `toast-badge.png` |
| Dumpling | `dumpling-bg.png` | `dumpling-badge.png` |
| Burger | `burger-bg.png` | `burger-badge.png` |
| Feast | `feast-bg.png` | `feast-badge.png` |
| Legend | `legend-bg.png` | `legend-badge.png` |

Twelve pictures in all. The free version of ChatGPT limits pictures per day, so it may take a couple of days. That's fine: save them as you go.
