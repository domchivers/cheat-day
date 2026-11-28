// Rows of one sheet of an unpacked .xlsx (no packages): node xlsx-rows.js <unpacked dir> <sheet n> [first] [count]
// Exported for other scripts as rows(dir, n) -> array of arrays of cell text.
const fs = require('fs'), path = require('path');
function rows(dir, n) {
  const ssPath = path.join(dir, 'xl', 'sharedStrings.xml');
  const ss = fs.existsSync(ssPath) ? [...fs.readFileSync(ssPath, 'utf8').matchAll(/<si>([\s\S]*?)<\/si>/g)]
    .map(m => [...m[1].matchAll(/<t[^>]*>([\s\S]*?)<\/t>/g)].map(t => t[1]).join('')) : [];
  const unesc = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  const xml = fs.readFileSync(path.join(dir, 'xl', 'worksheets', `sheet${n}.xml`), 'utf8');
  const out = [];
  for (const r of xml.matchAll(/<row[^>]*>([\s\S]*?)<\/row>/g)) {
    const row = [];
    for (const c of r[1].matchAll(/<c r="([A-Z]+)\d+"([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const colIdx = [...c[1]].reduce((a, ch) => a * 26 + ch.charCodeAt(0) - 64, 0) - 1;
      const attrs = c[2], body = c[3] || '';
      const v = (body.match(/<v>([\s\S]*?)<\/v>/) || [])[1];
      const inline = (body.match(/<t[^>]*>([\s\S]*?)<\/t>/) || [])[1];
      let val = '';
      if (/t="s"/.test(attrs) && v != null) val = ss[+v] ?? '';
      else if (v != null) val = v; else if (inline != null) val = inline;
      row[colIdx] = unesc(val);
    }
    out.push(row);
  }
  return out;
}
module.exports = { rows };
if (require.main === module) {
  const [dir, n, first = 0, count = 15] = process.argv.slice(2);
  rows(dir, n).slice(+first, +first + +count).forEach((r, i) => console.log(+first + i, JSON.stringify(r.slice(0, 22))));
}
