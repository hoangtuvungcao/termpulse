import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SITE_CONFIG, REPO_URL } from '../site.config.js';
import { PUBLIC_ASSETS } from './public-assets.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = path.join(root, 'dist');
if (!/^[A-Za-z0-9_.-]+$/.test(SITE_CONFIG.owner) || !/^[A-Za-z0-9_.-]+$/.test(SITE_CONFIG.repository)) throw new Error('Invalid public repository configuration.');
const canonical = new URL(SITE_CONFIG.canonicalUrl);
if (canonical.protocol !== 'https:' || canonical.username || canonical.password || canonical.search || canonical.hash || !['','/'].includes(canonical.pathname)) throw new Error('canonicalUrl must be an HTTPS origin.');
const canonicalUrl = canonical.origin;
// dist is generated output, never a source directory or caller-supplied path.
if (path.dirname(output) !== root || path.basename(output) !== 'dist') throw new Error('Unsafe build output path.');
await fs.rm(output, { recursive:true, force:true });
await fs.mkdir(path.join(output, 'assets'), { recursive:true });
const replacements = { CANONICAL_URL:canonicalUrl, REPO_URL, MAINTAINER_URL:`https://github.com/${SITE_CONFIG.owner}` };
for (const name of ['index.html','privacy.html','404.html']) {
  let html = await fs.readFile(path.join(root,name),'utf8');
  for (const [key,value] of Object.entries(replacements)) html = html.replaceAll(`{{${key}}}`,value);
  if (/\{\{[A-Z_]+\}\}/.test(html)) throw new Error(`Unresolved template value in ${name}`);
  await fs.writeFile(path.join(output,name),html);
}
for (const name of ['styles.css','app.js','i18n.js','releases.js','site.config.js','_headers']) await fs.copyFile(path.join(root,name),path.join(output,name));
for (const name of PUBLIC_ASSETS) await fs.copyFile(path.join(root,'assets',name),path.join(output,'assets',name));
await fs.writeFile(path.join(output,'robots.txt'),`User-agent: *\nAllow: /\nSitemap: ${canonicalUrl}/sitemap.xml\n`);
await fs.writeFile(path.join(output,'sitemap.xml'),`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${canonicalUrl}/</loc></url><url><loc>${canonicalUrl}/privacy.html</loc></url></urlset>\n`);
console.log(`Built ${output}: 3 pages, ${PUBLIC_ASSETS.length} reviewed assets, no runtime dependencies.`);
