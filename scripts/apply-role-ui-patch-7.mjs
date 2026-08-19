import fs from 'node:fs';
const path='index.html';
let html=fs.readFileSync(path,'utf8');
const before=`  const canManagePriceBook =\n    String(currentProfile?.role || '').toLowerCase() ===\n      'admin';`;
const after=`  const canManagePriceBook =\n    userCanManagePriceBooks();`;
if(!html.includes(before)) throw new Error('Missing price book role patch target');
html=html.replace(before,after);
fs.writeFileSync(path,html);
console.log('Updated open Price Book controls for Owner/Superintendent capabilities.');
