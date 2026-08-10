# Releasing

Mothball is Lab-tier, so this is light. The single non-obvious step
is the **macOS 13 floor check** — per-PR CI runs only on `macos-latest`
because GitHub-hosted `macos-13` runner capacity dried up in 2026-05,
but the README and `Package.swift` still promise `macOS 13+`. That
floor has to be exercised by hand before a tag.

## Per-tag checklist

Before pushing a release tag (`v0.x.y`):

1. **Update CHANGELOG / SPEC.md** to reflect what's actually in the tag.

2. **macOS 13 floor build + smoke test.** Either:
   - On a macOS 13 machine (VM, old laptop, or a colleague's box):
     ```
     swift --version          # confirm Swift 6.0+
     swift build              # must succeed
     swift test               # must pass
     swift run Mothball       # launch UI, scan a real dir, archive one repo
     ```
   - Or rerun the previously-dropped CI matrix locally via `act` /
     `docker` with a macos-13 image once GitHub restores runner
     capacity.

   If `swift build` fails on macOS 13 but succeeds on `macos-latest`,
   the regression is almost always an `if #available(macOS 14, *)`
   branch whose `else` clause uses another 14+ symbol. Fix that before
   the tag.

3. **License / SPEC drift sweep.** Quick:
   ```
   git diff --name-only $(git describe --tags --abbrev=0)..HEAD -- SPEC.md README.md LICENSE
   ```
   If LICENSE moved, SPEC.md and README must match.

4. **Tag + push.**
   ```
   git tag -s vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

5. **Verify post-tag CI on `main` is green** (PRs land via auto-merge,
   so the tagged commit is whichever auto-merged squash commit you're
   pinning).

## Why not automate the floor check

A `release.yml` triggered on tag push that queues a `macos-13` job
would work in principle, but at the current runner capacity (2026-05)
that job would sit in the queue for hours and the tag flow would
effectively block. When capacity returns, fold step 2 into a tag
workflow and delete this file.
