#!/bin/bash
# Copy the web app's food list, presets and Supabase settings into the native app.
# Run after editing foods.js, presets.js or supabase-config.js:  tools/native-data.sh
set -euo pipefail
cd "$(dirname "$0")/.."
node -e "
const fs = require('fs');
const run = (f, name) => new Function(fs.readFileSync(f, 'utf8') + ';return ' + name + ';')();
fs.writeFileSync('native/CheatDays/Resources/foods.json', JSON.stringify(run('foods.js', 'FOODS')));
fs.writeFileSync('native/CheatDays/Resources/presets.json', JSON.stringify(run('presets.js', 'PRESETS')));
const foods = JSON.parse(fs.readFileSync('tools/ai-test/data/food-db.json', 'utf8')).map(({ name, source, kcal, p, c, f }) => ({ name, source, kcal, p, c, f }));
fs.writeFileSync('native/CheatDays/Resources/aus-foods.json', JSON.stringify(foods));
fs.copyFileSync('tools/ai-test/aliases.json', 'native/CheatDays/Resources/aus-aliases.json');
for (const c of ['uk', 'us']) {   // CoFID 2021 and USDA SR Legacy, built by tools/ai-test/build-country-db.js
  const rows = JSON.parse(fs.readFileSync('tools/ai-test/data/' + c + '-foods.json', 'utf8')).map(({ name, source, kcal, p, c, f }) => ({ name, source, kcal, p, c, f }));
  fs.writeFileSync('native/CheatDays/Resources/' + c + '-foods.json', JSON.stringify(rows));
  fs.copyFileSync('tools/ai-test/' + c + '-aliases.json', 'native/CheatDays/Resources/' + c + '-aliases.json');
}
// every country's fallbacks, no aliases of their own: dishes as eaten (USDA FNDDS 2021-2023, build-country-db.js), then
// other countries' tables (build-world-db.js)
for (const t of ['dishes', 'world']) {
  const rows = JSON.parse(fs.readFileSync('tools/ai-test/data/' + t + '-foods.json', 'utf8')).map(({ name, source, kcal, p, c, f }) => ({ name, source, kcal, p, c, f }));
  fs.writeFileSync('native/CheatDays/Resources/' + t + '-foods.json', JSON.stringify(rows));
}
"
python3 - <<'EOF'
import re
src = open("supabase-config.js", encoding="utf-8").read()
url = re.search(r'url:\s*"([^"]+)"', src).group(1)
key = re.search(r'anonKey:\s*"([^"]+)"', src).group(1)
open("native/CheatDays/Net/SupabaseConfig.swift", "w", encoding="utf-8", newline="\n").write(
    "// Generated from supabase-config.js (the public anon key; row-level security protects the data).\n"
    "// Regenerate with tools/native-data.sh if the project changes.\nimport Foundation\n\n"
    "enum SupabaseConfig {\n"
    f"    static let url = URL(string: \"{url}\")!\n"
    f"    static let anonKey = \"{key}\"\n"
    "}\n")
EOF
echo "native data updated"
