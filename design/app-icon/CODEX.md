# Making the Cheat Days app icon with Codex

The idea, already approved as a rough sketch (`sketch.png`): **the week as a ring of seven segments, and the cheat day's segment is a whole pizza slice.** Six segments are plain ice-white ring pieces; the seventh, at the top, is a complete slice whose tip reaches the centre of the ring, nudged out slightly as if being picked up. Your job is to turn the sketch into a finished, smooth, simple, professional icon.

## Steps

1. If `icon.png` already exists, stop and tell the owner.
2. Generate **4 versions** with your image tool, using the prompt below word for word, square, 1024 x 1024 (or the closest square). Attach `sketch.png` as the reference for the layout.
3. Save them as `option-1.png` … `option-4.png` in `design/app-icon`.
4. Look at each and remake any that:
   - has text, letters or a border;
   - has rounded corners or a transparent background (it must be a full square, edge to edge);
   - doesn't keep the layout: seven segments around a ring, the top one a whole pizza slice reaching the centre;
   - looks busy, cartoonish or like clip art (faces, sparkles, glow, outlines, lots of toppings).
5. Pick the cleanest, copy it to `icon.png`, and run `python install.py` from `design/app-icon` (needs Pillow).
6. Tell the owner to open `design/app-icon/review.html` and look at the options. To use a different one, they copy it over `icon.png` and run `install.py` again.

## Rules

- Only `install.py` touches the app and the website (the app's icon file and `icons/icon-*.png`). Don't edit anything else, and don't commit.
- Don't change the prompt. If it keeps coming out wrong, say how.

## Prompt

```
A premium iOS app icon for "Cheat Days", a calorie tracker where six days are on plan and one is a cheat day. Follow the attached sketch's layout exactly, but make it smooth, refined and professional.

Composition: the week as a thick, clean ring divided into seven equal segments by small even gaps, centred. Six segments are soft ice white (#DCEAF7). The seventh, at the top, is a whole pizza slice: it fills its segment and keeps going inwards so its tip meets the centre of the ring, and its crust follows the ring's outer edge. It is nudged very slightly outwards, as if being picked up. The slice: warm golden cheese (#F4B740), a rounded golden-brown crust (#D9862F), and two or three simple pepperoni circles (#CF4733).

Background: deep navy, a very subtle vertical fade from #1C3052 at the top to #0E1A2E at the bottom, filling the whole square edge to edge.

Style: flat, modern vector with very gentle soft shading only, smooth rounded corners on every shape, crisp edges, generous padding (the design fills about 65% of the square), perfectly balanced and centred. Calm, confident and minimal, in the style of Apple's own app icons and premium indie apps like Things, Streaks and Headspace.

Avoid: text, letters, faces, outlines, glow, sparkles, gradients on the ring, extra toppings, cheese drips, borders, rounded-corner frames, transparency, 3D renders, clip-art look.

Square, 1024 x 1024.
```

## By hand (no Codex)

Paste the prompt into ChatGPT and attach `sketch.png`. Save the one you like as `design/app-icon/icon.png` and run `python install.py`, or send it to Claude to install.
