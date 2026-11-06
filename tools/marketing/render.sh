#!/bin/sh
# Instagram posts (1080×1350) from the demo screenshots, with headless Chrome or Edge.
#   1. copy the screenshots into tools/marketing/shots/ (names as in post.html)
#   2. sh tools/marketing/render.sh            → tools/marketing/out/post-1.png … post-6.png
cd "$(dirname "$0")" || exit 1
mkdir -p out
for b in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" "$(command -v google-chrome)" "$(command -v chromium)"; do
  [ -x "$b" ] && browser="$b" && break
done
[ -z "$browser" ] && { echo "No Chrome, Edge or Chromium found"; exit 1; }
here="$(pwd)"
for n in 1 2 3 4 5 6; do
  "$browser" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1080,1350 \
    --allow-file-access-from-files --virtual-time-budget=3000 --screenshot="$here/out/post-$n.png" "file://$here/post.html#$n" 2>/dev/null
  echo "out/post-$n.png"
done
