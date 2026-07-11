# Contributing

Thanks for considering a contribution. The most-wanted PRs are **whitelist additions** for local apps the tool doesn't yet recognize.

---

## Quick start

```bash
git clone https://github.com/heznpc/pc-health-check.git
cd pc-health-check
python3 -m pip install -r requirements-dev.txt
python3 -m pytest tests/ -q
swift test --package-path macos/PCHealthCheckMac
```

Both suites should pass before you start changing runtime contracts.

For a bug, use the general bug form. UI legibility, VoiceOver, keyboard, window sizing, and macOS design proposals have a dedicated accessibility/design form. Security vulnerabilities must use private reporting instead of either public form.

---

## Whitelist contributions

This is the highest-value contribution: adding a legitimate local app that currently triggers a false-positive warning.

### What goes in `data/whitelist.json`

- **Process name**: lowercased, **without** the `.exe` extension. Example: `i3gproc`, not `I3GProc.exe`.
- **Vendor**: official vendor name as it appears on the binary's digital signature, or the company's official English name. Example: `Initech`, `WIZVERA Co., Ltd.`.
- **Description**: one short sentence in Korean (preferred) or English explaining what the process does in plain language. Example: `"공인인증서 인증 모듈 (은행/공공기관 접속 시 자동 실행)"`.
- **Category**: pick one from the existing top-level keys:
  - `system` — OS-bundled (Microsoft / Apple)
  - `browser` — major browsers and their helpers
  - `korean_common` — Korean software widely installed but not security-related (messenger, Hangul, etc.)
  - `banking_security` — Korean banking/government security plugins (IPinside, MagicLine, INISAFE, etc.)
  - `dev_tools` — developer tools (Docker, Node, IDE helpers)
  - `hardware` — vendor tools (NVIDIA, AMD, printer drivers)
  - `cloud` — Dropbox, OneDrive, iCloud, etc.

### Example PR diff

```json
"banking_security": {
  "your_process_here": {
    "vendor": "Vendor Co., Ltd.",
    "desc": "이 프로세스가 하는 일 (한 줄)",
    "risk": "safe"
  }
}
```

### What gets rejected

- Adversarial / typo-squatted process names (`svch0st`, `chrorne`, etc.) — these belong in `miner_blacklist`, not the whitelist.
- Processes without a verifiable vendor.
- Generic process names that overlap with malware families (case-by-case review).
- Personal favorites unrelated to Korean/Japanese local context — this is a locale-aware tool, not a global whitelist.

---

## Code contributions

### Pre-PR checklist

- [ ] `python3 -m pytest tests/ -q` passes.
- [ ] `python3 scripts/release_smoke.py --check-only` passes.
- [ ] If you touched the Mac app, `swift test --package-path macos/PCHealthCheckMac` passes.
- [ ] If you touched Mac packaging, `scripts/package_macos_release.sh --local` completes and its app, DMG, and sidecar metadata report the intended architectures/minimum OS. This never creates a publishable release.
- [ ] If you touched a PowerShell script, run a parse check:
      `pwsh -Command "[System.Management.Automation.Language.Parser]::ParseFile('scripts/<file>.ps1', [ref]\$null, [ref]\$null)"`.
- [ ] If you touched `rules/*.json`, validate JSON:
      `for f in rules/*.json; do python3 -c "import json; json.load(open('$f'))"; done`.
- [ ] No new runtime dependencies (the tool is intentionally dependency-free).
- [ ] No PII or user-PC scan artifacts (`scan_result.json`, `monitor_result.json`, `검사결과*.html`) committed — they're gitignored.
- [ ] No local `data/config.json`, API key, email address, build-machine home path, or unexpected symlink appears in an artifact. Edit only `data/config.example.json` when changing defaults.

### Style

- Python: standard library only. f-strings, type hints where it helps clarity, `pathlib.Path` over `os.path`.
- PowerShell: target PS 5.1 (Windows built-in). Avoid PS Core-only features.
- Bash: portable, no `bashisms` past v3.2 (default macOS bash).

### What needs design discussion before a PR

- Adding any external dependency (Python package, npm module, PowerShell module).
- Changing cleanup approval boundaries, bundle-ID attribution, or protected-history behavior.
- Adding a new outbound network path or changing standalone runtime packaging/signing.
- Changing release architecture, minimum OS, artifact audit rules, or the clean-tag/notarization gate.
- Adding telemetry, analytics, or any phone-home behavior.
- Changes to the VirusTotal integration that send more than a SHA-256 hash.

Open a discussion or draft issue first for any of these.

---

## i18n contributions

Translations live in two places:

- `docs/i18n/{ko,en,ja}.json` — landing page strings.
- `data/report_i18n/{ko,en,ja}.json` — HTML report strings.

To add a new language:

1. Copy `en.json` from both directories.
2. Rename to `<code>.json` where `<code>` is a [BCP 47 primary subtag](https://en.wikipedia.org/wiki/IETF_language_tag) (e.g., `zh`, `vi`, `id`).
3. Translate values only — keep keys exactly as in `en.json`.
4. Add the code to the `SUPPORTED` array in `docs/script.js`.

**Important — XSS hygiene:** translation strings can include a small whitelist of HTML tags (`<em>`, `<strong>`, `<code>`, `<a>`, `<br>`, `<span>`) for typography. Everything else is stripped by the sanitizer in `docs/script.js`. **Do not** include `<script>`, `<iframe>`, `<img>`, `on*` event handlers, or `javascript:` URLs — they'll be silently removed, and a PR with deliberate attempts will be rejected.

If you modify `sanitizeHTML` in `docs/script.js`, **always re-run the sanitizer smoke test**:

```bash
cd docs && python3 -m http.server 8000
# open http://localhost:8000/sanitize-test.html
```

All rows must be green. If any are red, the sanitizer regressed — fix before opening the PR. The test harness lives at `docs/sanitize-test.html` and covers the standard XSS surface (script/iframe/img/svg, `javascript:`/`data:`/`vbscript:` schemes with case + whitespace + entity-encoded bypasses, `on*` handler injection, nested elements, comment nodes).

---

## Security

Found a vulnerability? **Do not open a public issue.** See [`SECURITY.md`](./SECURITY.md) for the private disclosure path.

---

## License

By contributing, you agree that your contribution will be licensed under the MIT License (see `LICENSE`).
