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
export function selectReleaseAssets(release, owner, repository) {
  const selected = Object.fromEntries(PLATFORMS.map((platform) => [platform, null]));
  if (!release || release.draft || release.prerelease || !Array.isArray(release.assets)) return selected;
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
