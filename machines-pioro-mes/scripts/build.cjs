'use strict';
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const destination = path.join(root, 'public');
fs.mkdirSync(destination, { recursive: true });
for (const file of ['index.html', '_headers']) fs.copyFileSync(path.join(root, file), path.join(destination, file));
console.log('Gotowe: public/index.html i public/_headers. Żadne dane użytkownika nie są dołączane.');
