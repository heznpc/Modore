# Security policy

Mothball is a Lab-tier macOS app (see `README.md` — pre-alpha scaffold,
not production-ready). The security surface is intentionally narrow:
no network I/O, no external dependencies, no remote services, no user
accounts. The only privileged operations are `git`, `tar`, and `mv to
Trash` against directories the user explicitly selected.

## Reporting a vulnerability

Please report security issues privately. Do **not** open a public
GitHub issue.

- Preferred: GitHub Security Advisory — "Report a vulnerability" tab
  on this repository.
- Fallback: email `wantcongz@gmail.com` with subject prefix
  `[mothball-security]`.

I will acknowledge within 7 days and aim to ship a fix on the next
release. Lab-tier project: there is no SLA.

## In scope

- Argument injection or path traversal in the `ProcessRunner` flow.
- Failure modes that would silently delete data without the archive
  + trash recovery layers described in `README.md`.
- Sidecar manifest schema bugs that would prevent restore via
  `git clone` for a fully-pushed repo.

## Out of scope

- Anything that requires a malicious local user with shell access to
  the same Mac — the threat model assumes the local user is trusted.
- macOS sandbox escapes from a hypothetical sandboxed build — Mothball
  is not currently sandboxed.
- Performance / DoS via deeply nested directories — Lab-tier; will be
  triaged but not gated.

## Automated security tooling — known gap

There is **no automated static analysis** on this repo today. CodeQL
Swift is the obvious fit, but GitHub Code Scanning requires a GitHub
Advanced Security license, which is not enabled on this private free-
plan repository (`security_and_analysis: null` via the REST API).
Secret scanning and push protection are off for the same reason.

Active automated controls that *are* in place:

- Dependabot vulnerability alerts + automated security fixes.
- Dependabot GitHub Actions update PRs (weekly, grouped).
- CI build + integration tests on every push and PR.

Manual control for argv-injection / path-traversal regressions (the
two in-scope risks above) is contributor review of any new
`ProcessRunner.run` or `validateSource` call site. Re-evaluate the
GHAS gap if the repo goes public or if a sponsor enables Advanced
Security.
