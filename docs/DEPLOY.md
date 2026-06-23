# GitHub Pages Deployment Guide

This `docs/` folder is a static landing page ready for GitHub Pages.

## Quick deploy (5 minutes)

### 1. Push to GitHub

```bash
cd /path/to/pc-health-check
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/heznpc/pc-health-check.git
git push -u origin main
```

### 2. Enable GitHub Pages

1. Go to your repo → **Settings** → **Pages**
2. Under **Source**, select **Deploy from a branch**
3. Branch: `main`, Folder: `/docs`
4. Click **Save**

After ~1 minute your site is live at:
```
https://heznpc.github.io/pc-health-check/
```

## Custom domain (optional)

1. Buy a domain (e.g. `pchealth.example.com`)
2. Create `docs/CNAME` with a single line: `pchealth.example.com`
3. At your domain registrar, add a CNAME record pointing to `heznpc.github.io`
4. In Settings → Pages → Custom domain, enter your domain

GitHub Pages provides free TLS automatically.

## Local preview

```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

Test with different languages via URL param:
- `http://localhost:8000/?lang=ko`
- `http://localhost:8000/?lang=en`
- `http://localhost:8000/?lang=ja`

## Adding a language

1. Copy `docs/i18n/en.json` to `docs/i18n/<code>.json` (e.g. `zh.json`, `fr.json`, `es.json`)
2. Translate each value (keep the keys in English)
3. Edit `docs/script.js`:
   ```js
   const SUPPORTED = ['ko', 'en', 'ja', 'zh'];  // add code here
   ```
4. Edit `docs/index.html` — add a button inside `<div class="lang-switcher">`:
   ```html
   <button class="lang-btn" data-lang="zh">中文</button>
   ```

That's it. No build step.

## Updating releases

When you cut a new release, the download links in `docs/index.html` already point to `releases/latest` so they auto-update.

Build and verify the release artifacts first:

```bash
python3 scripts/release_smoke.py
cat dist/release-manifest.json
```

The smoke build creates:
- `dist/pch-v0.3.0-win.zip`
- `dist/pch-v0.3.0-mac.zip`
- `dist/release-manifest.json` with SHA-256 checksums

To publish a release:
```bash
git tag v0.3.0
git push origin v0.3.0
```

Then on GitHub: Releases → Draft new release → select tag → attach both zips and paste the checksums from `dist/release-manifest.json`.

## SEO tips (optional)

- Add `docs/robots.txt` (allow all) if you want Google to index
- Add Open Graph image: create `docs/og-image.png` (1200×630) and add `<meta property="og:image">` in `index.html`
- Submit to Google Search Console
- Translate the `<html lang>` attribute dynamically — already handled by `script.js`
