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
