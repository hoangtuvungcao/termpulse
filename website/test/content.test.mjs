import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { EN } from '../i18n.js';
import { PUBLIC_ASSETS } from '../scripts/public-assets.mjs';
const root = new URL('../',import.meta.url);
test('English covers every translated visible label and accessible name',async() => {
  for (const name of ['index.html','privacy.html']) {
    const html = await fs.readFile(new URL(name,root),'utf8');
    for (const match of html.matchAll(/data-i18n(?:-aria|-alt)?="([^"]+)"/g)) assert.equal(typeof EN[match[1]],'string',`Missing English copy: ${name} ${match[1]}`);
  }
});
test('source references only explicitly reviewed public image assets',async() => {
  for (const name of ['index.html','privacy.html','404.html']) {
    const html = await fs.readFile(new URL(name,root),'utf8');
    for (const match of html.matchAll(/(?:src|href)="\/?assets\/([^"?#]+)"/g)) assert.ok(PUBLIC_ASSETS.includes(match[1]),`Unreviewed asset: ${match[1]}`);
  }
  for (const asset of PUBLIC_ASSETS) assert.ok((await fs.stat(new URL(`assets/${asset}`,root))).isFile());
});
test('privacy copy preserves encryption limits and platform caveats in both languages',async() => {
  const html = await fs.readFile(new URL('privacy.html',root),'utf8');
  assert.match(html,/không phải mã hóa toàn bộ cơ sở dữ liệu/);assert.match(html,/not full-database encryption/);assert.match(html,/localStorage/);assert.match(html,/data-policy-language="en"/);assert.match(html,/id="permissions"/);
});
