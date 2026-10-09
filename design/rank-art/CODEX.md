# Generating Cheat Days' rank art with Codex

**Job list:** `design/rank-art/jobs.json` has 12 jobs: a background and a badge for each of the six ranks. Each job gives:
- `file`: where to save the image, relative to `design/rank-art`;
- `group`: `test` (Dumpling only) or `ranks` (the other five);
- `size`: the canvas size;
- `refs`: images to attach as style references (none for the test);
- `prompt`: the full prompt, to use word for word.

## Round 1: the test

Do only the jobs in group **`test`** (Dumpling's background and badge).

1. If `file` already exists, skip it.
2. Generate one image with your image generation tool, using `prompt` exactly, at `size` or the closest you can.
3. Save it as PNG at `file`, creating `out/raw/` if needed.
4. Look at it. Make it once more if:
   - the background isn't very dark, or its left half isn't mostly empty;
   - there's any text in it;
   - the badge's backdrop isn't flat solid magenta.
5. Run `python process.py` from `design/rank-art`. It needs Pillow and numpy.
6. Stop there and tell the owner to open `design/rank-art/out/review.html`.

## Round 2: the rest (only after the owner says the test looks right)

Do the jobs in group **`ranks`** the same way, in order. Attach every image in `refs` as a style reference: these are the approved Dumpling pictures, so all six ranks match. Report progress after every 4 images. When they're all made, run `python process.py` again and tell the owner to open `out/review.html`.

## Rules

- Don't edit the app, and don't commit the images.
- Don't change the prompts. If one keeps coming out wrong, say which one and why.
