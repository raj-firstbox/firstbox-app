// Copies the two libraries the page needs into web/vendor, so the app works without loading them from the internet.
const fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..'), out = path.join(root, 'web', 'vendor');
fs.mkdirSync(out, { recursive: true });
const copies = [
  ['node_modules/@supabase/supabase-js/dist/umd/supabase.js', 'supabase.js'],
  ['node_modules/pdf-lib/dist/pdf-lib.min.js', 'pdf-lib.min.js'],
];
for (const [from, to] of copies) {
  fs.copyFileSync(path.join(root, from), path.join(out, to));
  console.log('vendor/' + to);
}
