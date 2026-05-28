# Mothball

> **Status: Lab — pre-alpha. Not yet usable for normal workflows.**
> Mothball will move directories to the Trash for you. Read the
> "Design intent" section before you point it at anything you care
> about.

Git-aware project archiver for macOS. Compresses dormant repositories
to `.tar.zst`, writes a sidecar manifest with origin / branch / HEAD,
and moves the original to the trash.

## What it does

Scans paths you choose for git repositories. Inspects each — last
commit date, working-tree state, whether HEAD is pushed to origin —
and classifies them as **safe**, **caution**, or **unsafe** to
archive. You pick which to archive; Mothball compresses the project
(including `.git`), verifies the archive is readable, then moves the
original to the trash. The sidecar JSON next to each archive carries
enough metadata to restore via `git clone <origin>` for any repo that
was fully pushed.

## Build

Requires macOS 13+ and Swift 6.0+ (Xcode 16+, full Xcode toolchain —
Command Line Tools alone does not include `XCTest`). Strict
concurrency is on by default; the codebase is Sendable-clean.

```
swift build
swift test
swift run Mothball
```

Integration tests under `Tests/` exercise real `git` and `tar`
binaries; individual cases auto-skip when those aren't present at
`/usr/bin`. Note that the test target itself requires the full Xcode
XCTest module to compile in the first place — on a machine with only
Command Line Tools, `swift test` fails with `no such module 'XCTest'`
before any skip logic runs.

## Project layout

| Path | Role |
|---|---|
| `Sources/MothballCore/` | Library: scanner, classifier, archive pipeline, process wrapper. No SwiftUI dependency. |
| `Sources/MothballApp/`  | SwiftUI surface: first-run consent, scan view, confirm sheet, progress overlay, settings. |
| `Tests/`                | Unit + integration tests. |
| `SPEC.md`               | Detailed v0.1 spec and v0.2+ backlog. |

## Currently implemented

- Path scanner that walks user-chosen directories for git working trees.
- Git inspector: last commit date, dirty state, ahead-of-upstream, fully-pushed check.
- Safety classifier: `safe` / `caution` / `unsafe` based on push state, dirty state, and recency.
- Archive pipeline: `tar` + `zstd` to `.tar.zst`, sidecar JSON manifest, integrity verify, trash move.
- SwiftUI shell: first-run consent, scan view, confirm sheet, progress overlay, settings screen, activity log.
- Optional `git fetch` before classification (off by default).
- Integration tests against real `git` / `tar` binaries; green on macOS CI.

## Planned

- Restore command (read sidecar manifest → `git clone` for pushed repos).
- Archive history browser inside the app.
- Time-series growth analysis (which paths grew the most between scans).
- See `SPEC.md` v0.2+ backlog for the full list.

## Design intent

- **Git-aware, not mtime-only.** Existing macOS "stale project" cleaners (ClearDisk, Mole, kondo, npkill) use file mtime or node_modules heuristics. They will happily delete a repo whose `main` is ahead of `origin` by 30 commits. Mothball refuses to call that `safe`. Push state is load-bearing, not decorative.
- **Archive, then trash — never silent delete.** The output is a recoverable `.tar.zst` next to a manifest, and the original goes to the Trash (recoverable) before any user-visible "done." If something is wrong, the user has two undo layers.
- **Classify, then ask.** The classifier never archives anything on its own. `safe` / `caution` / `unsafe` is a recommendation; the user picks. Caution exists specifically because the binary "ok/not ok" is wrong for real repos (e.g. clean tree, fully pushed, but only 3 days old).
- **`MothballCore` has no SwiftUI dependency.** Library is testable headless. Tests exercise real `git` and `tar` rather than mocks because the bugs that matter live in argv quoting, exit codes, and FS edge cases — not in the parts a mock would cover.

## Non-goals

- General macOS cache / launchctl cleaner (ClearDisk and Mole own that turf).
- Disk visualization or treemaps (DaisyDisk own that turf).
- Single-folder `node_modules` deleter (kondo and npkill own that turf).
- Real-time background disk monitor or menu-bar daemon — out of scope for v0.x.
- Cloud sync, multi-machine archive index, or remote restore service.

## Redacted

None for this repo.

## Part of: Human-Controlled AI Systems

Mothball is a Lab-tier tool — destructive operations stay reversible
(archive + trash) and the classifier never acts without the user's
confirmation. Same shape as the rest of the portfolio: the human
keeps the steering wheel.
