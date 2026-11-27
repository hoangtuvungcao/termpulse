# TermPulse website

Public website: https://termpulse.pages.dev
Source and community: https://github.com/hoangtuvungcao/termpulse

This dependency-free static website lives in the app repository's `website/` directory. It includes Vietnamese and English pages, a privacy policy, reviewed demonstration screenshots and download links resolved from real GitHub Releases.

## Build and verify

From the repository root:

```sh
cd website
npm test
npm run build
npm run check
```

Only the generated `dist/` directory may be published. The build copies an explicit allowlist of public assets; local screenshots and other source files are not deployment artifacts.

## Cloudflare Pages

The `termpulse` Pages project is connected to the public GitHub repository:

- Production branch: `main`
- Root directory: `website`
- Build command: `node scripts/build.mjs`
- Output directory: `dist`

GitHub Actions also runs website tests and produces a static-site artifact.

For an authenticated one-off deployment:

```sh
npx wrangler@4 pages deploy dist --project-name termpulse --branch main
```

Never deploy the source directory or place deployment tokens in site configuration.

## Public metadata and downloads

Edit `site.config.js` for the repository, canonical address and public project metadata. Do not invent a legal publisher or contact email. Keep signing, installation and encryption limitations visible. Download buttons must use verified assets from the intended GitHub repository and clearly identify any community preview.
