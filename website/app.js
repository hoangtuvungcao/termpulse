import { SITE_CONFIG, REPO_URL, RELEASE_API } from './site.config.js';
import { EN, DYNAMIC } from './i18n.js';
import { PLATFORMS, selectReleaseAssets, safeReleaseUrl, formatSize } from './releases.js';

const sourceCopy = new Map();
const selectors = [['[data-i18n]','i18n','textContent'],['[data-i18n-aria]','i18nAria','aria-label'],['[data-i18n-alt]','i18nAlt','alt']];
for (const [selector, attribute, property] of selectors) {
  for (const element of document.querySelectorAll(selector)) {
    sourceCopy.set(element.dataset[attribute], property === 'textContent' ? element.textContent : element.getAttribute(property));
  }
}
const storage = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key,value) { try { localStorage.setItem(key,value); } catch { /* Preference persistence is optional. */ } },
};
const requestedLanguage = new URLSearchParams(location.search).get('lang');
let language = requestedLanguage === 'en' || requestedLanguage === 'vi' ? requestedLanguage : storage.get('tp_lang') || (navigator.language.startsWith('vi') ? 'vi' : 'en');
if (!['vi','en'].includes(language)) language = 'vi';
let releaseState = { kind:'loading', release:null };
let releaseRequest = 0;
const t = (key) => DYNAMIC[language][key] ?? (language === 'en' ? EN[key] : sourceCopy.get(key)) ?? key;

function applyLanguage(value) {
  language = value === 'en' ? 'en' : 'vi';
  document.documentElement.lang = language;
  storage.set('tp_lang',language);
  const select = document.getElementById('langSelect');
  if (select) select.value = language;
  for (const [selector, attribute, property] of selectors) {
    for (const element of document.querySelectorAll(selector)) {
      const key = element.dataset[attribute];
      const text = language === 'en' ? EN[key] : sourceCopy.get(key);
      if (typeof text !== 'string') continue;
      if (property === 'textContent') element.textContent = text;
      else element.setAttribute(property,text);
    }
  }
  for (const element of document.querySelectorAll('[data-policy-language]')) element.hidden = element.dataset.policyLanguage !== language;
  document.title = t(document.body.dataset.page === 'privacy' ? 'privacyPageTitle' : 'pageTitle');
  renderRelease();
}

function applyTheme(value) {
  const theme = value === 'light' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  storage.set('tp_theme',theme);
  document.getElementById('themeToggleBtn')?.setAttribute('aria-pressed',String(theme === 'light'));
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content',theme === 'light' ? '#fbfcff' : '#0b101a');
}

function renderRelease() {
  const status = document.getElementById('releaseStatus');
  if (!status) return;
  const {kind,release} = releaseState;
  const assets = selectReleaseAssets(release,SITE_CONFIG.owner,SITE_CONFIG.repository);
  status.replaceChildren();
  if (kind === 'loading') status.textContent = t('releaseLoading');
  else if (kind === 'error') status.textContent = t('releaseError');
  else if (!release) status.textContent = t('releaseEmpty');
  else {
    status.append(`${t('releaseAvailable')} `);
    const link = document.createElement('a');
    link.href = safeReleaseUrl(release.html_url,SITE_CONFIG.owner,SITE_CONFIG.repository) || `${REPO_URL}/releases`;
    link.textContent = release.tag_name || release.name || 'GitHub Release';
    status.append(link);
    if (release.published_at && Number.isFinite(Date.parse(release.published_at))) {
      status.append(` · ${t('updated')} ${new Intl.DateTimeFormat(language === 'vi' ? 'vi-VN' : 'en-GB',{dateStyle:'medium'}).format(new Date(release.published_at))}`);
    }
    if (!Object.values(assets).some(Boolean)) status.append(`. ${t('releaseNoFiles')}`);
  }
  for (const platform of PLATFORMS) {
    const anchor = document.querySelector(`[data-download="${platform}"]`);
    if (!anchor) continue;
    const asset = assets[platform];
    const label = anchor.querySelector('[data-download-label]');
    const detail = document.querySelector(`[data-asset="${platform}"]`);
    if (asset && kind === 'ready') {
      anchor.href = safeReleaseUrl(asset.browser_download_url,SITE_CONFIG.owner,SITE_CONFIG.repository);
      anchor.removeAttribute('aria-disabled');
      anchor.removeAttribute('tabindex');
      anchor.setAttribute('aria-label',`${t('download')} ${asset.name}`);
      label.textContent = t('download');
      if (detail) detail.textContent = `${asset.name} · ${formatSize(asset.size)}`;
    } else {
      anchor.removeAttribute('href');
      anchor.setAttribute('aria-disabled','true');
      anchor.setAttribute('tabindex','-1');
      anchor.removeAttribute('aria-label');
      label.textContent = t(kind === 'loading' ? 'checking' : 'unavailable');
      if (detail) detail.textContent = kind === 'loading' ? '' : t('noAsset');
    }
  }
  const retry = document.getElementById('retryReleases');
  if (retry) retry.hidden = kind !== 'error';
}

async function loadReleases() {
  const request = ++releaseRequest;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(),8000);
  releaseState = {kind:'loading',release:null};
  renderRelease();
  try {
    const response = await fetch(RELEASE_API,{headers:{Accept:'application/vnd.github+json'},signal:controller.signal,credentials:'omit',referrerPolicy:'no-referrer'});
    if (request !== releaseRequest) return;
    if (response.status === 404) releaseState = {kind:'ready',release:null};
    else {
      if (!response.ok) throw new Error('RELEASE_UNAVAILABLE');
      const release = await response.json();
      if (!release || typeof release.tag_name !== 'string' || release.draft || release.prerelease || !Array.isArray(release.assets)) throw new Error('RELEASE_INVALID');
      releaseState = {kind:'ready',release};
    }
  } catch {
    if (request === releaseRequest) releaseState = {kind:'error',release:null};
  } finally {
    clearTimeout(timer);
    if (request === releaseRequest) renderRelease();
  }
}

const links = {source:REPO_URL,releases:`${REPO_URL}/releases`,issues:`${REPO_URL}/issues`,discussions:`${REPO_URL}/discussions`,maintainer:`https://github.com/${SITE_CONFIG.owner}`};
for (const anchor of document.querySelectorAll('[data-link]')) if (links[anchor.dataset.link]) anchor.href = links[anchor.dataset.link];
for (const element of document.querySelectorAll('[data-publisher]')) element.textContent = SITE_CONFIG.publisher;
for (const element of document.querySelectorAll('[data-policy-version]')) element.textContent = SITE_CONFIG.policyVersion;
for (const element of document.querySelectorAll('[data-privacy-email]')) {
  if (SITE_CONFIG.privacyEmail && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(SITE_CONFIG.privacyEmail)) {
    element.textContent = SITE_CONFIG.privacyEmail;
    element.href = `mailto:${SITE_CONFIG.privacyEmail}`;
    element.hidden = false;
  }
}
document.getElementById('year')?.replaceChildren(String(new Date().getFullYear()));
document.getElementById('langSelect')?.addEventListener('change',(event) => applyLanguage(event.target.value));
document.getElementById('themeToggleBtn')?.addEventListener('click',() => applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'));
const menu = document.getElementById('main-nav');
const menuToggle = document.getElementById('menuToggle');
function closeMenu() { menu?.classList.remove('open');menuToggle?.setAttribute('aria-expanded','false'); }
menuToggle?.addEventListener('click',() => {const open = !menu?.classList.contains('open');menu?.classList.toggle('open',open);menuToggle.setAttribute('aria-expanded',String(open));});
menu?.addEventListener('click',(event) => {if (event.target.closest('a')) closeMenu();});
document.addEventListener('click',(event) => {if (!event.target.closest('.navbar')) closeMenu();});
document.addEventListener('keydown',(event) => {if (event.key === 'Escape' && menu?.classList.contains('open')) {closeMenu();menuToggle?.focus({preventScroll:true});}});
matchMedia('(min-width: 721px)').addEventListener('change',(event) => {if (event.matches) closeMenu();});
for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click',() => {
  for (const item of document.querySelectorAll('[data-filter]')) {const active = item === button;item.classList.toggle('active',active);item.setAttribute('aria-pressed',String(active));}
  for (const card of document.querySelectorAll('[data-category]')) card.hidden = button.dataset.filter !== 'all' && card.dataset.category !== button.dataset.filter;
});
const lightbox = document.getElementById('lightbox');
const lightboxImage = document.getElementById('lightboxImg');
let lightboxTrigger = null;
for (const trigger of document.querySelectorAll('[data-lightbox]')) trigger.addEventListener('click',() => {
  const image = trigger.querySelector('img');
  if (!image || !lightbox || !lightboxImage) return;
  lightboxTrigger = trigger;
  lightboxImage.src = image.currentSrc || image.src;
  lightboxImage.alt = image.alt;
  document.getElementById('lightboxCaption').textContent = t(trigger.dataset.caption);
  lightbox.showModal();
  document.body.classList.add('modal-open');
});
document.getElementById('lightboxClose')?.addEventListener('click',() => lightbox.close());
lightbox?.addEventListener('click',(event) => {if (event.target !== lightbox) return;const bounds = lightbox.getBoundingClientRect();if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) lightbox.close();});
lightbox?.addEventListener('close',() => {document.body.classList.remove('modal-open');lightboxImage?.removeAttribute('src');lightboxTrigger?.focus({preventScroll:true});});
document.getElementById('retryReleases')?.addEventListener('click',loadReleases);
applyTheme(storage.get('tp_theme') || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'));
applyLanguage(language);
if (document.getElementById('releaseStatus')) loadReleases();
