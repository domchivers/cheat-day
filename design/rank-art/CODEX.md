# Generating Cheat Days' rank badges with Codex

**Job list:** `design/rank-art/jobs.json` has 6 jobs, one badge per rank. (Backgrounds were dropped: the app draws a metal trim along the calorie panel instead.) Each job gives:
- `file`: where to save the image, relative to `design/rank-art`;
- `group`: `test` (Dumpling, already made and approved) or `ranks` (the other five);
- `size`: the canvas size;
- `refs`: images to attach as style references;
- `prompt`: the full prompt, to use word for word.

## Make the badges

Do the jobs in group **`ranks`**, in order.

1. If `file` already exists, skip it.
2. Generate one image with your image generation tool, using `prompt` exactly, at `size` or the closest you can. Attach every image in `refs` as a style reference: that's the approved Dumpling badge, so all six match.
3. Save it as PNG at `file`.
4. Look at it. Make it once more if:
   - there's text in it;
   - the backdrop isn't flat solid magenta;
   - it doesn't look like the same set as the Dumpling badge.
5. When all five are made, run `python process.py` then `python install.py` from `design/rank-art`. They need Pillow and numpy.
6. Tell the owner to open `design/rank-art/out/review.html`.

## Rules

- Only `install.py` touches the app, by copying the badges into its asset catalogue. Don't edit anything else, and don't commit.
- Don't change the prompts. If one keeps coming out wrong, say which one and why.
