// Reads one sheet of an unzipped .xlsx into rows of strings and numbers. No dependencies.
const fs = require('fs'), path = require('path');
const unescape = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
function column(ref) { let n = 0; for (const c of ref.match(/^[A-Z]+/)[0]) n = n * 26 + c.charCodeAt(0) - 64; return n - 1; }
function readSheet(dir, sheet) {
  const shared = [...fs.readFileSync(path.join(dir, 'xl/sharedStrings.xml'), 'utf8').matchAll(/<si>([\s\S]*?)<\/si>/g)]
    .map(m => unescape([...m[1].matchAll(/<t[^>]*>([^<]*)<\/t>/g)].map(t => t[1]).join('')));
  const xml = fs.readFileSync(path.join(dir, 'xl/worksheets', `sheet${sheet}.xml`), 'utf8');
  const rows = [];
  for (const r of xml.matchAll(/<row [^>]*>([\s\S]*?)<\/row>/g)) {
    const row = [];
    for (const c of r[1].matchAll(/<c r="([A-Z]+\d+)"([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const v = c[3] && c[3].match(/<v>([^<]*)<\/v>/);
      if (!v) continue;
      row[column(c[1])] = /t="s"/.test(c[2]) ? shared[+v[1]] : /t="str"/.test(c[2]) ? unescape(v[1]) : +v[1];
    }
    rows.push(row);
  }
  return rows;
}
module.exports = { readSheet };
