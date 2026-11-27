import test from 'node:test';
import assert from 'node:assert/strict';
import { selectReleaseAssets, safeReleaseUrl, formatSize } from '../releases.js';
const owner = 'hoangtuvungcao';
const repo = 'termpulse';
const asset = (name, extra={}) => ({name,size:10_000,state:'uploaded',browser_download_url:`https://github.com/${owner}/${repo}/releases/download/v1/${name}`,...extra});
const release = (...assets) => ({draft:false,prerelease:false,assets});
test('selects existing platform assets, preferring a universal Android package',() => {
  const result = selectReleaseAssets(release(asset('termpulse-android-arm64.apk'),asset('termpulse-android-universal.apk'),asset('termpulse-windows-x64.zip'),asset('termpulse-macos-universal.zip'),asset('termpulse-linux-x64.tar.gz')),owner,repo);
  assert.equal(result.android.name,'termpulse-android-universal.apk');
  assert.equal(result.windows.name,'termpulse-windows-x64.zip');
  assert.equal(result.macos.name,'termpulse-macos-universal.zip');
  assert.equal(result.linux.name,'termpulse-linux-x64.tar.gz');
});
test('leaves unavailable platforms disabled instead of manufacturing URLs',() => {
  const result = selectReleaseAssets(release(asset('termpulse-linux-x64.tar.gz')),owner,repo);
  assert.equal(result.android,null);assert.equal(result.windows,null);assert.equal(result.macos,null);assert.ok(result.linux);
});
test('does not offer draft, prerelease, debug, unsigned or non-installable assets',() => {
  assert.equal(selectReleaseAssets({...release(asset('app.apk')),draft:true},owner,repo).android,null);
  assert.equal(selectReleaseAssets({...release(asset('app.apk')),prerelease:true},owner,repo).android,null);
  const result = selectReleaseAssets(release(asset('app-debug.apk'),asset('app-unsigned.apk'),asset('app.aab'),asset('app.ipa'),asset('termpulse-linux-symbols.zip'),asset('app.apk',{state:'new'})),owner,repo);
  assert.ok(Object.values(result).every((item) => item === null));
});
test('rejects off-site and wrong-repository links supplied in release data',() => {
  for (const url of ['https://evil.example/app.apk','http://github.com/hoangtuvungcao/termpulse/releases/download/v1/app.apk','https://github.com/another/termpulse/releases/download/v1/app.apk','https://github.com/hoangtuvungcao/termpulse-evil/releases/download/v1/app.apk','javascript:alert(1)','https://user:password@github.com/hoangtuvungcao/termpulse/releases/download/v1/app.apk']) assert.equal(safeReleaseUrl(url,owner,repo),null);
  const result = selectReleaseAssets(release(asset('app.apk',{browser_download_url:'https://evil.example/app.apk'})),owner,repo);
  assert.equal(result.android,null);
});
test('handles absent or malformed assets and formats file sizes',() => {
  assert.ok(Object.values(selectReleaseAssets(null,owner,repo)).every((item) => item === null));
  assert.equal(selectReleaseAssets(release(null,{},asset('app.apk',{size:0})),owner,repo).android,null);
  assert.equal(formatSize(1024),'1 KB');assert.equal(formatSize(5 * 1024 * 1024),'5.0 MB');
});
