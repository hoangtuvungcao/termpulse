// Pure release selection functions are shared by the site and its Node tests.
export const PLATFORMS = Object.freeze(['android', 'windows', 'macos', 'linux']);
export function safeReleaseUrl(value, owner, repository) {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value);
    const prefix = `/${owner}/${repository}/releases/`;
    return url.protocol === 'https:' && url.hostname === 'github.com' && !url.port && !url.username && !url.password && url.pathname.startsWith(prefix) ? url.href : null;
  } catch { return null; }
}
export function selectReleaseAssets(release, owner, repository, { allowPrerelease = false } = {}) {
  const selected = Object.fromEntries(PLATFORMS.map((platform) => [platform, null]));
  if (!release || release.draft || (release.prerelease && !allowPrerelease) || !Array.isArray(release.assets)) return selected;
  const candidates = release.assets.filter((asset) => asset && typeof asset.name === 'string' && asset.state === 'uploaded' && Number.isFinite(asset.size) && asset.size > 0 && !/debug|unsigned|universal-test|\.aab$|\.ipa$|symbols|checksums?|sha256/i.test(asset.name) && safeReleaseUrl(asset.browser_download_url, owner, repository));
  const rules = {
    android: (name) => /\.apk$/i.test(name),
    windows: (name) => /(?:windows|win(?:32|64)?)[-_\.]/i.test(name) && /\.(?:zip|exe|msi)$/i.test(name),
    macos: (name) => /(?:macos|darwin|osx)[-_\.]/i.test(name) && /\.(?:zip|dmg|tar\.gz)$/i.test(name),
    linux: (name) => /linux[-_\.]/i.test(name) && /\.(?:tar\.gz|tar\.xz|zip|appimage|deb|rpm)$/i.test(name),
  };
  for (const platform of PLATFORMS) {
    const choices = candidates.filter((asset) => rules[platform](asset.name));
    choices.sort((a, b) => score(b.name, platform) - score(a.name, platform) || a.name.localeCompare(b.name));
    if (choices[0]) selected[platform] = choices[0];
  }
  return selected;
}
function score(name, platform) {
  if (platform === 'android') return /universal/i.test(name) ? 4 : /arm64|aarch64/i.test(name) ? 3 : /armeabi/i.test(name) ? 2 : 1;
  return /universal/i.test(name) ? 3 : /x86_64|x64|amd64/i.test(name) ? 2 : 1;
}
export function formatSize(bytes) { return bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`; }


// The list API is explicitly sorted by publication time rather than relying on
// GitHub's list order. Stable releases always win over newer previews.
export function selectPublishedRelease(releases, owner, repository, { allowPrerelease = false } = {}) {
  if (!Array.isArray(releases)) return null;
  const date = release => Date.parse(release.published_at || release.created_at || '') || 0;
  const published = releases
    .filter(release => release && release.draft === false && Array.isArray(release.assets))
    .sort((a, b) => date(b) - date(a) || Number(b.id || 0) - Number(a.id || 0));
  const stable = published.find(release => release.prerelease === false);
  if (stable) return stable;
  if (!allowPrerelease) return null;
  return published.find(release => {
    if (release.prerelease !== true || typeof release.tag_name !== 'string' ||
        !/^community-preview-/i.test(release.tag_name)) return false;
    const selected = selectReleaseAssets(release, owner, repository, { allowPrerelease: true });
    return ['windows', 'macos', 'linux'].some(platform => selected[platform]);
  }) || null;
}

// Only GitHub release-list requests receive this normalization. Failed API
// responses remain failures; no download URL is invented.
export async function fetchPublishedRelease(input, init = {}, fetchImpl = globalThis.fetch) {
  let endpoint;
  try { endpoint = new URL(String(input)); } catch { return fetchImpl(input, init); }
  const match = /^\/repos\/([^/]+)\/([^/]+)\/releases(?:\/latest)?$/.exec(endpoint.pathname);
  if (endpoint.protocol !== 'https:' || endpoint.hostname !== 'api.github.com' ||
      endpoint.port || endpoint.username || endpoint.password || !match) return fetchImpl(input, init);
  const [, owner, repository] = match;
  endpoint.pathname = '/repos/' + owner + '/' + repository + '/releases';
  endpoint.search = '?per_page=100';
  endpoint.hash = '';
  const response = await fetchImpl(endpoint.href, init);
  if (!response.ok) return response;
  const payload = await response.json();
  if (!Array.isArray(payload)) {
    return new Response(JSON.stringify({ message: 'Invalid GitHub release-list response.' }), {
      status: 502, headers: { 'Content-Type': 'application/json' },
    });
  }
  const release = selectPublishedRelease(payload, owner, repository, { allowPrerelease: true });
  if (!release) return new Response('null', { status: 404, headers: { 'Content-Type': 'application/json' } });
  return new Response(JSON.stringify({
    ...release,
    __termpulseCommunityPreview: release.prerelease === true,
    __termpulseCommunityPreviewUrl: 'https://github.com/' + owner + '/' + repository +
      '/releases/tag/' + encodeURIComponent(release.tag_name),
  }), { status: 200, headers: { 'Content-Type': 'application/json' } });
}
