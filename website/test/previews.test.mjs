import test from 'node:test';
import assert from 'node:assert/strict';
import { selectReleaseAssets, selectPublishedRelease, fetchPublishedRelease } from '../releases.js';
import { communityPreviewCopy } from '../i18n.js';

const owner = 'hoangtuvungcao';
const repository = 'termpulse';
const latest = 'https://api.github.com/repos/' + owner + '/' + repository + '/releases/latest';
const tag = 'community-preview-2026-11-27';
const asset = name => ({
  name, size: 123456, state: 'uploaded',
  browser_download_url: 'https://github.com/' + owner + '/' + repository + '/releases/download/' + tag + '/' + name,
});
const preview = (extra = {}) => ({
  draft: false, prerelease: true, tag_name: tag, id: 2,
  published_at: '2026-11-27T09:00:00Z',
  html_url: 'https://github.com/' + owner + '/' + repository + '/releases/tag/' + tag,
  assets: [asset('TermPulse-linux-x64.deb'), asset('TermPulse-windows-x64.zip'),
    asset('TermPulse-macos-arm64.dmg'), asset('app-debug.apk'), asset('TermPulse-unsigned.ipa')],
  ...extra,
});
const stable = (extra = {}) => preview({
  prerelease: false, tag_name: 'v0.1.0', published_at: '2026-11-20T09:00:00Z', ...extra,
});
const json = (value, status = 200) => new Response(JSON.stringify(value), { status });

test('prerelease assets need a fourth-argument opt-in and unsafe mobile assets stay excluded', () => {
  const release = preview();
  assert.deepEqual(Object.values(selectReleaseAssets(release, owner, repository)), [null, null, null, null]);
  const selected = selectReleaseAssets(release, owner, repository, { allowPrerelease: true });
  assert.equal(selected.linux.name, 'TermPulse-linux-x64.deb');
  assert.equal(selected.android, null);
  assert.doesNotMatch(JSON.stringify(selected), /app-debug\.apk|TermPulse-unsigned\.ipa/);
});

test('newest published stable wins over a newer preview regardless of API list order', () => {
  const newestStable = stable({ tag_name: 'v0.2.0', published_at: '2026-11-25T00:00:00Z' });
  const result = selectPublishedRelease([preview(), newestStable, stable()], owner, repository, { allowPrerelease: true });
  assert.equal(result, newestStable);
});

test('drafts are ignored and only an explicitly allowed named community preview is a fallback', () => {
  const releases = [
    stable({ draft: true, published_at: '2026-11-29T00:00:00Z' }),
    preview({ tag_name: 'unrelated-beta', published_at: '2026-11-28T00:00:00Z' }),
    preview(),
  ];
  assert.equal(selectPublishedRelease(releases, owner, repository), null);
  assert.equal(selectPublishedRelease(releases, owner, repository, { allowPrerelease: true }), releases[2]);
});

test('debug-only, unsigned-only, offsite, and non-uploaded previews cannot enable download cards', () => {
  for (const assets of [
    [asset('app-debug.apk')],
    [asset('TermPulse-linux-unsigned.zip')],
    [{ ...asset('TermPulse-linux-x64.deb'), browser_download_url: 'https://example.com/evil.deb' }],
    [{ ...asset('TermPulse-linux-x64.deb'), state: 'new' }],
    [{ ...asset('TermPulse-linux-x64.deb'), browser_download_url: 'https://github.com:8443/hoangtuvungcao/termpulse/releases/download/x/test.deb' }],
  ]) assert.equal(selectPublishedRelease([preview({ assets })], owner, repository, { allowPrerelease: true }), null);
});

test('fetch uses the list API and preserves stable preference and request options', async () => {
  const calls = [];
  const options = { headers: { Accept: 'application/vnd.github+json' } };
  const response = await fetchPublishedRelease(latest, options, async (url, init) => {
    calls.push({ url: String(url), init });
    return json([preview(), stable()]);
  });
  const release = await response.json();
  assert.equal(release.prerelease, false);
  assert.equal(release.__termpulseCommunityPreview, false);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.github.com/repos/hoangtuvungcao/termpulse/releases?per_page=100');
  assert.equal(calls[0].init, options);
});

test('a selected community preview receives an explicit marker and canonical asset-page link', async () => {
  const response = await fetchPublishedRelease(latest, {}, async () => json([preview()]));
  const release = await response.json();
  assert.equal(release.tag_name, tag);
  assert.equal(release.__termpulseCommunityPreview, true);
  assert.equal(release.__termpulseCommunityPreviewUrl,
    'https://github.com/hoangtuvungcao/termpulse/releases/tag/' + tag);
});

test('empty lists stay unavailable, malformed lists fail, and API failures are preserved', async () => {
  assert.equal((await fetchPublishedRelease(latest, {}, async () => json([]))).status, 404);
  assert.equal((await fetchPublishedRelease(latest, {}, async () => json({}))).status, 502);
  const forbidden = json({}, 403);
  assert.equal(await fetchPublishedRelease(latest, {}, async () => forbidden), forbidden);
  const external = json({ unchanged: true });
  assert.equal(await fetchPublishedRelease('https://example.com/releases/latest', {}, async () => external), external);
});

test('preview notice has translation parity and clearly describes unsigned desktop packages', () => {
  assert.deepEqual(Object.keys(communityPreviewCopy.vi).sort(), Object.keys(communityPreviewCopy.en).sort());
  assert.match(communityPreviewCopy.vi.warning, /chưa được ký số/);
  assert.match(communityPreviewCopy.en.warning, /desktop packages are unsigned/);
});

