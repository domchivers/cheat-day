"""Downloads Microsoft's Fluent Emoji (flat, MIT licence) for every emoji FoodEmoji uses, into the app's asset catalogue
as vector images named food-<codepoints>. Run from the repo root: python tools/fluent.py"""
import io, json, os, re, sys, urllib.request, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEME = os.path.join(ROOT, "native", "CheatDays", "Views", "Theme.swift")
OUT = os.path.join(ROOT, "native", "CheatDays", "Assets.xcassets", "Food")

def code(e):
    return "-".join(f"{ord(c):x}" for c in e if ord(c) != 0xFE0F)

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "cheatdays-tools"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

s = io.open(THEME, encoding="utf-8").read()
part = s[s.index("enum FoodEmoji"):s.index("static func `for`")]
# the food table's emoji, plus the ones the app uses elsewhere (Me page tiles, settings)
EXTRA = ["🔥", "🎯", "📈", "📖", "🗓️", "🏆", "👨‍👩‍👧", "⚙️"]
emojis = list(dict.fromkeys(re.findall(r'\("([^"]+)", \[', part) + EXTRA))

tree = json.loads(get("https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/main?recursive=1"))["tree"]
paths = [t["path"] for t in tree]
metas = [p for p in paths if p.startswith("assets/") and p.endswith("/metadata.json") and p.count("/") == 2]
flats = {p.split("/")[1]: p for p in paths if re.match(r"assets/[^/]+/Flat/[^/]+_flat\.svg$", p)}

# which folder holds which emoji: read each folder's metadata (unicode field), only for folders with a flat svg
want = {code(e): e for e in emojis}
found = {}
cache = os.path.join(ROOT, "tools", ".fluent-index.json")   # kept (git-ignored) so a rerun is quick
index = json.load(open(cache)) if os.path.exists(cache) else {}
for m in metas:
    folder = m.split("/")[1]
    if folder not in flats: continue
    if folder not in index:
        try: index[folder] = json.loads(get("https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/" + urllib.parse.quote(m))).get("unicode", "")
        except Exception: index[folder] = ""
    u = index[folder].replace(" ", "-").lower()
    u = "-".join(x for x in u.split("-") if x != "fe0f")
    if u in want and u not in found: found[u] = folder
    if len(found) == len(want): break
json.dump(index, open(cache, "w"))

os.makedirs(OUT, exist_ok=True)
io.open(os.path.join(OUT, "Contents.json"), "w").write(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, indent=2))
for u, folder in found.items():
    d = os.path.join(OUT, f"food-{u}.imageset")
    os.makedirs(d, exist_ok=True)
    io.open(os.path.join(d, "icon.svg"), "wb").write(get("https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/" + urllib.parse.quote(flats[folder])))
    io.open(os.path.join(d, "Contents.json"), "w").write(json.dumps({
        "images": [{"filename": "icon.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True}}, indent=2))
missing = [u for u in want if u not in found]
print(f"{len(found)} icons; missing: {missing}")
