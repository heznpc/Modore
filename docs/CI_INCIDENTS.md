# CI incidents

Open **프로젝트·대화 찾기 → CI 문제** (or `modore://work/ci`). Refresh imports
repositories from the latest 100 GitHub CI notifications and the local Work
projects' verified `origin` URLs. An owner/name field adds a repository explicitly.
Existing GitHub CLI authentication is used; Modore does not copy credentials or
change GitHub notification/read state.

The collector checks up to 24 repositories, 50 recent workflow runs per repository,
and at most eight new failed-run diagnostics per repository per collection. The
view states this coverage and shows repository lookup errors. An absent run outside
that window is unknown, not healthy. GitHub CLI must be installed in a standard
Homebrew or system location and authenticated for github.com.

Failures are grouped within repository, workflow, branch, event and source-repository
identity, using failed steps and normalized error evidence. First collection is
silent. Repeated matching failures update the same incident and counters. When logs
are unavailable, the UI explicitly says the grouping is by failed step and the
root cause requires inspection. Only short excerpts are retained; common credential,
email and local-home identifiers are masked. This is not a guarantee that arbitrary
third-party logs contain no sensitive content. Full logs stay on GitHub.

A newer successful run in the same lane verifies recovery. Queued, cancelled,
skipped or unreadable runs never do. A changed diagnostic supersedes the old symptom
without claiming recovery. A PR verified as no longer open leaves the unresolved
list with a distinct inactive state. Failure to read PR status does not dismiss it.

**Check every 5 minutes** is opt-in and runs while Modore is running. New incident
and recovery events produce one combined native notification per change batch.
Unchanged failures are quiet. Notification events are acknowledged only after the
notification center accepts delivery; failed delivery can retry. Clicking the
notification opens the CI view. Turning this on does not change GitHub email settings.

Related work is joined by local Git origin, not inferred blame. Selecting a project
opens its conversations. **Copy repair request for agent** supplies a run link,
commit, failed steps and bounded evidence. The agent must inspect actual logs,
implement a correction and verify the new run. Modore does not run log-provided
commands, change source code, weaken gates or merge automatically.

```sh
modore ci refresh --discover
modore ci refresh --repo owner/repository --project /absolute/project/path
modore ci status
```

The `ci_incident_status` MCP tool reads the saved snapshot only. It never contacts
GitHub, refreshes state or acknowledges notifications. Check `checkedAt`, per-repo
errors and evidence level before diagnosing. State is atomically stored under
`~/Library/Application Support/Modore/ci/state.json`; CLI and app collectors share a
nonblocking lock. Requests have bounded output, subprocess timeouts and an overall
collection budget. No daemon is installed.

Tests cover silent baseline, duplicate and changed failures, interrupted runs,
older successes, cross-branch/fork recovery isolation, PR retirement, partial
collection, redaction, stable fingerprints, selective delivery acknowledgments,
read-only MCP, and native navigation/link validation.
