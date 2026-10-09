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
