# Cheat Days

Spend your cheat-day calories on purpose. Set a budget (say 1,600 kcal), scan
what you're about to eat, say how big a slice of the day it should be ("10%",
"1/6", "250 kcal") and it tells you how many grams, servings or pieces that is.
Add it to the day and watch the ring fill up.

No accounts, no server, no build step. Everything stays on the device.

## How to open

**Double-click `start.bat`** — it starts a tiny local server and opens the app.
Keep the black window open while you use it.

### On your phone (same Wi-Fi)

1. On the PC, run `start.bat`. It prints the address to use, e.g.
   `http://192.168.1.103:8010/index.html`. The first time, Windows may ask to
   let Python through the firewall — allow it.
2. Open that address in Safari / Chrome on the phone.
3. **Share → Add to Home Screen** for an app icon.

## Three ways to add an item

| Source | What happens |
| --- | --- |
| **Scan a barcode** | Reads the barcode (live camera, or a photo of it) and looks the product up on [Open Food Facts](https://world.openfoodfacts.org). Free, no key needed. Not every product is there — you can always type the number or fill in the pack yourself. |
| **Photo of the label** | Sends the photo to Claude, which reads the nutrition table (kcal per 100 g, serving size, pack size, pieces). Needs an Anthropic API key entered once in Settings; the key stays in the browser's local storage on that device. |
| **Type it in** | You enter kcal per 100 g (or per serving) and whatever else you know. |

Whatever the source, you land on an editable "check the details" form before
choosing your share, so a wrong reading is a quick fix rather than a wrong day.

## Shares you can type

`10%` · `1/6` · `0.15` · `15` (means 15%) · `250 kcal` · or tap **What's left**
to spend the remainder of the day.

## Camera note

Browsers only allow the *live* camera feed over HTTPS or `localhost`. Over a
plain `http://192.168…` address on your phone, the app falls back to the
phone's camera app via "take a photo" — the barcode is decoded from that photo.
Both routes are automatic; you'll just see one button or the other.

## Files

- `index.html`, `styles.css`, `app.js` — the whole app
- `vendor/zxing.min.js` — barcode decoding ([@zxing/library](https://github.com/zxing-js/library) 0.21.3, UMD build)
- `sw.js`, `manifest.webmanifest`, `icons/` — install-to-home-screen and offline cache
- `make_icons.py` — regenerates the icons (needs Pillow)
- `start.bat` — local server on port 8010

When you change app files, bump the `?v=` numbers in `index.html` and
`CACHE` in `sw.js` so installed copies pick up the new version.
