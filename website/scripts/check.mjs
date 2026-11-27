import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {PUBLIC_ASSETS} from './public-assets.mjs';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..','dist');
const allowed = new Set(['index.html','privacy.html','404.html','styles.css','app.js','i18n.js','releases.js','site.config.js','_headers','robots.txt','sitemap.xml',...PUBLIC_ASSETS.map((name) => `assets/${name}`)]);
async function walk(directory,prefix='') {const files=[];for(const entry of await fs.readdir(directory,{withFileTypes:true})){const relative=`${prefix}${entry.name}`;if(entry.isSymbolicLink())throw new Error(`No symlinks may be deployed: ${relative}`);if(entry.isDirectory())files.push(...await walk(path.join(directory,entry.name),`${relative}/`));else files.push(relative);}return files;}
const files = await walk(root);
for(const file of files)if(!allowed.has(file))throw new Error(`Unreviewed deployment file: ${file}`);
for(const expected of allowed)if(!files.includes(expected))throw new Error(`Missing deployment file: ${expected}`);
for(const name of ['index.html','privacy.html','404.html']){
  const html=await fs.readFile(path.join(root,name),'utf8');
  if(/\{\{[A-Z_]+\}\}/.test(html))throw new Error(`Unresolved template in ${name}`);
  const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map((match)=>match[1]);
  if(new Set(ids).size!==ids.length)throw new Error(`Duplicate IDs in ${name}`);
  for(const match of html.matchAll(/(?:src|href)="([^"]+)"/g)){
    if(/^(?:https:|mailto:|#)/.test(match[1]))continue;
    const target=match[1].split(/[?#]/)[0];
    if(!target)continue;
    const relative=target==='/'?'index.html':target.replace(/^\//,'');
    if(!allowed.has(relative))throw new Error(`Broken local reference in ${name}: ${match[1]}`);
  }
}
console.log(`Validated ${files.length} allowlisted deployment files, local links, unique IDs and resolved metadata.`);
