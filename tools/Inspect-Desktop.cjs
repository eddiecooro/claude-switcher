// Read-only inspection of the installed Electron archive; never reads account data.
const fs = require('fs');
const archive = fs.readFileSync(process.argv[2]);
const headerSize = archive.readUInt32LE(4);
const tree = JSON.parse(archive.subarray(16, 16 + archive.readUInt32LE(12)).toString());
const names = [];
function walk(node, prefix = '') {
  for (const [name, entry] of Object.entries(node.files || {})) {
    const path = prefix + name;
    if (entry.files) walk(entry, path + '/');
    else if (/\.js$/.test(path) && !entry.unpacked && !path.includes('node_modules/')) names.push([path, entry]);
  }
}
walk(tree);
const options = process.argv.slice(3);
const fileFilter = options.find(x => x.startsWith('--file='))?.slice(7);
const maxCount = Number(options.find(x => x.startsWith('--count='))?.slice(8) || 3);
const radius = Number(options.find(x => x.startsWith('--radius='))?.slice(9) || 700);
const patterns = options.filter(x => !x.startsWith('--'));
for (const [path, entry] of names) {
  if (fileFilter && !path.includes(fileFilter)) continue;
  const start = 8 + headerSize + Number(entry.offset);
  const code = archive.subarray(start, start + entry.size).toString();
  for (const pattern of patterns) {
    let pos = -1, count = 0;
    while ((pos = code.indexOf(pattern, pos + 1)) >= 0 && count++ < maxCount) {
      console.log(JSON.stringify({ path, pattern, snippet: code.slice(Math.max(0, pos - radius / 2), pos + radius) }));
    }
  }
}
