// Public project metadata. Never place deployment tokens or other secrets here.
export const SITE_CONFIG = Object.freeze({
  owner: 'hoangtuvungcao',
  repository: 'termpulse',
  canonicalUrl: 'https://termpulse.pages.dev',
  publisher: 'hoangtuvungcao',
  // Leave empty until the maintainer supplies an address for public use.
  privacyEmail: '',
  policyVersion: '2026-11-27',
});
export const REPO_URL = `https://github.com/${SITE_CONFIG.owner}/${SITE_CONFIG.repository}`;
export const RELEASE_API = `https://api.github.com/repos/${SITE_CONFIG.owner}/${SITE_CONFIG.repository}/releases/latest`;
