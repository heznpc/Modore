# Mothball

Git-aware project archiver for macOS. Compresses dormant repositories
to `.tar.zst`, writes a sidecar manifest with origin/branch/HEAD info,
and moves the original to the trash.

> Status: pre-alpha scaffold. Not yet usable for normal workflows.

## What it does

Scans paths you choose for git repositories. Inspects each — last
commit date, working-tree state, whether HEAD is pushed to origin —
and classifies them as **safe**, **caution**, or **unsafe** to
archive. You pick which to archive; Mothball compresses the project
(including `.git`), verifies the archive is readable, then moves the
original to the trash.

The sidecar JSON next to each archive carries enough metadata to
restore via `git clone <origin>` for any repo that was fully pushed.

## Build

Requires macOS 13+ and Swift 5.9+ (Xcode 15+).

```
swift build
swift test
swift run Mothball
```

Integration tests under `Tests/` exercise real `git` and `tar`
binaries; they auto-skip when those aren't present at `/usr/bin`.

## Project layout

| Path | Role |
|---|---|
| `Sources/MothballCore/` | Library: scanner, classifier, archive pipeline, process wrapper. No SwiftUI dependency. |
| `Sources/MothballApp/`  | SwiftUI surface: first-run consent, scan view, confirm sheet, progress overlay, settings. |
| `Tests/`                | Unit + integration tests. |
| `SPEC.md`               | Design decisions and v0.2+ backlog. |

## Status

**v0.1 (now)**: scan, classify, archive pipeline, trash move,
basic UI, activity log, optional `git fetch` before classification,
integration tests.

**Not yet**: restore command, archive history browser, time-series
growth analysis. See `SPEC.md`.
