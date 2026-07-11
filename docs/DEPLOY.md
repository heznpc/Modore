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

While the project is in source-preview status, both download cards in `docs/index.html` intentionally point to the repository. When the first public release is published, update and review both card links to `https://github.com/heznpc/pc-health-check/releases/latest`; they do not change automatically.

Build and verify the release artifacts first:

```bash
python3 -I -B scripts/release_smoke.py
```

The default smoke build writes commit-labelled, non-publishable ZIPs and a manifest under `dist/local/`. It never uses the canonical public filenames.

Build an unsigned, non-publishable Universal 2 DMG smoke artifact in its isolated path:

```bash
scripts/package_macos_release.sh --local
```

Public packaging is intentionally fail-closed. First commit and review every change, create the exact SSH-signed annotated `v<version>` tag at `HEAD`, and confirm that the worktree/index are clean. Both the source ZIP builder and Mac packager verify the immutable tag payload directly with `ssh-keygen` against an anonymous, externally pinned `heznpc` allowed-signers descriptor before and after their isolated build steps. Then supply the Developer ID identity and an existing `notarytool` Keychain profile externally:

```bash
PCH_RELEASE_SIGNER_PUBLIC_KEY='ssh-ed25519 <reviewed-public-key-base64>' \
PCH_RELEASE_SIGNER_SHA256='SHA256:<reviewed-fingerprint>' \
python3 -I -B scripts/release_smoke.py --release --version 0.3.0
cat dist/release-manifest.json

PCH_APP_VERSION=0.3.0 \
PCH_CODESIGN_IDENTITY="Developer ID Application identity from Keychain" \
PCH_CODESIGN_TEAM_ID="ABCDE12345" \
PCH_CODESIGN_CERT_SHA256="<reviewed-64-hex-leaf-certificate-fingerprint>" \
PCH_NOTARY_PROFILE="local-keychain-profile" \
PCH_RELEASE_SIGNER_PUBLIC_KEY='ssh-ed25519 <reviewed-public-key-base64>' \
PCH_RELEASE_SIGNER_SHA256='SHA256:<reviewed-fingerprint>' \
scripts/package_macos_release.sh
```

The release ZIP builder reads payloads from the verified Git commit, and the Mac packager builds from an isolated `git archive` snapshot; both disable and reject Git replace objects. The script validates Universal 2 slices, macOS 13 minimum deployment, app/DMG payload and metadata audit, pinned-signer tag verification, the reviewed Developer ID Team ID and leaf-certificate SHA-256, notarization, stapling, and Gatekeeper before publishing the sidecar and then the DMG completion marker. Metadata records both source-tag and Developer ID trust anchors; local artifacts keep those identity fields null. Attach the source ZIPs, notarized DMG, `*.dmg.metadata.json`, and source `release-manifest.json` only after every gate succeeds. This repository currently has no published installer; do not present an artifact from `dist/local/` as a release.

## SEO tips (optional)

- Add `docs/robots.txt` (allow all) if you want Google to index
- Add Open Graph image: create `docs/og-image.png` (1200×630) and add `<meta property="og:image">` in `index.html`
- Submit to Google Search Console
- Translate the `<html lang>` attribute dynamically — already handled by `script.js`
