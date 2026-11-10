"""Downloads Microsoft's Fluent Emoji in 3D (MIT licence) for the story editor's built-in stickers, into the app's asset
catalogue as sticker-<codepoints> (256 px PNGs). Run from the repo root: python tools/fluent3d.py
The list is in STICKERS below; it shares tools/.fluent-index.json with fluent.py, so a rerun is quick."""
import io, json, os, re, urllib.request, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "native", "CheatDays", "Assets.xcassets", "Stickers")

# food, drink, training and feelings: what people put on a food and fitness story
STICKERS = ("🍕 🍔 🌮 🌯 🥗 🍜 🍣 🍱 🍛 🍝 🥩 🍗 🥓 🍳 🥞 🧇 🥐 🥑 🍓 🍌 🍎 🍉 🫐 🥦 🥕 🌶️ 🧀 🥚 🍞 🍰 🍩 🍪 🍫 🍦 🧁 🍿 "
            "☕ 🥤 🧋 🍷 🍺 🥂 💧 🍽️ 🥄 "
            "💪 🏋️ 🏃 🚴 🧘 🤸 ⚽ 🏆 🥇 🔥 ⚡ ✨ 🎉 🎯 ⏰ 📈 ❤️ 💯 "
            "😋 🤤 🥵 😮‍💨 😴 🤯 😂 🥳 😎 🤩 🙌 👏 👀 💀").split()

def code(e):
    return "-".join(f"{ord(c):x}" for c in e if ord(c) != 0xFE0F)

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "cheatdays-tools"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

tree = json.loads(get("https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/main?recursive=1"))["tree"]
paths = [t["path"] for t in tree]
metas = [p for p in paths if p.startswith("assets/") and p.endswith("/metadata.json") and p.count("/") == 2]
threes = {p.split("/")[1]: p for p in paths if re.match(r"assets/[^/]+/3D/[^/]+_3d\.png$", p)}
# people and hands come in skin tones: their default yellow one
for p in paths:
    if re.match(r"assets/[^/]+/Default/3D/[^/]+_3d_default\.png$", p): threes.setdefault(p.split("/")[1], p)

want = {code(e): e for e in STICKERS}
found = {}
cache = os.path.join(ROOT, "tools", ".fluent-index.json")
index = json.load(open(cache)) if os.path.exists(cache) else {}
for m in metas:
    folder = m.split("/")[1]
    if folder not in threes: continue
    if folder not in index:
        try: index[folder] = json.loads(get("https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/" + urllib.parse.quote(m))).get("unicode", "")
        except Exception: index[folder] = ""
    u = "-".join(x for x in index[folder].replace(" ", "-").lower().split("-") if x != "fe0f")
    if u in want and u not in found: found[u] = folder
    if len(found) == len(want): break
json.dump(index, open(cache, "w"))

os.makedirs(OUT, exist_ok=True)
io.open(os.path.join(OUT, "Contents.json"), "w").write(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, indent=2))
for u, folder in found.items():
    d = os.path.join(OUT, f"sticker-{u}.imageset")
    os.makedirs(d, exist_ok=True)
    io.open(os.path.join(d, "sticker.png"), "wb").write(get("https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/" + urllib.parse.quote(threes[folder])))
    io.open(os.path.join(d, "Contents.json"), "w").write(json.dumps({
        "images": [{"filename": "sticker.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2))
# the list in the order given, for the app (only the ones found)
order = [code(e) for e in STICKERS if code(e) in found]
io.open(os.path.join(ROOT, "native", "CheatDays", "Resources", "stickers.json"), "w", encoding="utf-8").write(json.dumps(
    [{"code": c, "emoji": want[c]} for c in order], ensure_ascii=False))
missing = [want[u] for u in want if u not in found]
print(f"{len(found)} stickers; missing: {missing}")
