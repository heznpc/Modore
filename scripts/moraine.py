#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Moraine, Modore's leave-behind audit: what stays after the installer is gone.

Uninstalling software rarely removes everything it placed, and the moraines
that matter most are the ones that keep acting on the machine after the app that
put them there no longer exists.

Two sources, both read-only, both surviving the uninstall they describe:

- **Installer receipts** (`pkgutil`). macOS records every package ever installed
  and never forgets, so the receipt outlives the payload. A receipt whose files
  are all gone is the fingerprint of something that was here and was removed.
- **Trust-store roots** (`security dump-trust-settings`). A root certificate a
  vendor added is not a file in a folder; it is an entry inside the system
  trust store. Deleting the app does not touch it, and a trusted root keeps
  validating TLS for as long as it is valid.

Correlating the two is the point: a *trusted root whose installing package has
no payload left on disk* is a certificate still vouching for a vendor that is
otherwise gone from the machine. That is the verdict this module exists to
produce, and neither source alone can produce it.

Prior art, and why this is not it: AppCleaner
(https://freemacsoft.net/appcleaner/) is the reference for moraine hunting on
macOS and its location list is genuinely vetted -- its bundled BundlePaths.plist
plus binary string table cover ~70 /Library and ~/Library directories including
LaunchAgents, LaunchDaemons, PrivilegedHelperTools, StartupItems, Extensions,
and /private/var/db/receipts. Two structural differences leave a gap it cannot
close:

- It is target-driven. You drop an app on it and it finds that app's files. When
  the app is already gone there is nothing to drop, and the moraines have no
  owner to search from. This runs the other direction, residue first, the
  same inversion scree applies to session stores.
- It treats `/Library/Keychains` as a directory of files and receipts as files
  to delete. Its binary contains no SecTrust or SecCertificate symbols at all
  (checked directly, 2026-08-19), so trust-store *contents* -- the entries that
  actually carry authority -- are outside what a file sweep can reach.

Judgment limits (preview-grade evidence, never deletion authorization):
- attribution links a certificate to a package by vendor token, so a vendor that
  names its package differently from its certificate reads as `unattributed`
  rather than being guessed at;
- an `unattributed` root is not thereby suspicious: MDM profiles, enterprise
  Wi-Fi, and hand-imported roots legitimately have no installer receipt;
- large packages are file-sampled, and any sampling is reported.

Writes nothing; all output goes to stdout. Deletion is never performed and never
suggested as automatic -- removing a trust root is an admin-authority act that
belongs to the person at the keyboard.
"""
from __future__ import annotations

import argparse
import calendar
import json
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

PKGUTIL = "/usr/sbin/pkgutil"
SECURITY = "/usr/bin/security"
# The system LibreSSL, not whatever a package manager put earlier on PATH: its
# output format is what the parsers below are written against, and pinning the
# absolute path keeps this deterministic across machines.
OPENSSL = "/usr/bin/openssl"

COMMAND_TIMEOUT = 60
# Per-package file check ceiling. Xcode-class receipts list tens of thousands of
# paths; stat()ing all of them for every package turns a report into a disk
# crawl. Sampling is always reported, never silent.
FILE_SAMPLE_CAP = 200

Runner = Callable[[list[str], Optional[str]], "tuple[int, str]"]


def run_command(args: list[str], stdin_text: Optional[str] = None) -> tuple[int, str]:
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=COMMAND_TIMEOUT,
                              input=stdin_text,
                              stdin=None if stdin_text is not None else subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return proc.returncode, proc.stdout


# ---------------------------------------------------------------------------
# Installer receipts
# ---------------------------------------------------------------------------

APPLE_PKG_PREFIXES = ("com.apple.",)


def _vendor_of_pkgid(pkgid: str) -> str:
    """`com.innorix.innorixexagent.ca.pkg` -> `com.innorix`.

    Reverse-DNS second component is the vendor namespace the vendor itself
    chose, which is why this is a read rather than a guess. Ids that do not
    look reverse-DNS fall back to the whole id.
    """
    parts = pkgid.split(".")
    return ".".join(parts[:2]) if len(parts) >= 2 else pkgid


def collect_receipts(run: Runner = run_command, *,
                     sample_cap: int = FILE_SAMPLE_CAP) -> tuple[list[dict], dict]:
    code, out = run([PKGUTIL, "--pkgs"], None)
    if code != 0:
        return [], {"source": "receipts", "status": "unavailable",
                    "detail": "pkgutil did not run", "count": 0}
    pkgids = [line.strip() for line in out.splitlines() if line.strip()]
    receipts: list[dict] = []
    unreadable = 0
    for pkgid in sorted(pkgids):
        code, info_out = run([PKGUTIL, "--pkg-info-plist", pkgid], None)
        if code != 0:
            unreadable += 1
            continue
        try:
            info = plistlib.loads(info_out.encode("utf-8"))
        except (ValueError, plistlib.InvalidFileException):
            unreadable += 1
            continue
        volume = info.get("volume") or "/"
        location = info.get("install-location") or ""
        root = Path(volume) / location if location else Path(volume)

        code, files_out = run([PKGUTIL, "--files", pkgid], None)
        relatives = [line.strip() for line in files_out.splitlines() if line.strip()] \
            if code == 0 else []
        sampled = len(relatives) > sample_cap
        checked = relatives[:sample_cap]
        present = sum(1 for rel in checked if (root / rel).exists())
        if not checked:
            # A payload-free receipt (a script-only package) cannot be judged by
            # file presence, so it is reported as its own state rather than
            # being folded into "vanished".
            state = "no_payload"
        elif present == 0:
            state = "vanished"
        elif present == len(checked):
            state = "present"
        else:
            state = "partial"
        install_time = info.get("install-time")
        receipts.append({
            "pkgid": pkgid,
            "vendor": _vendor_of_pkgid(pkgid),
            "apple": pkgid.startswith(APPLE_PKG_PREFIXES),
            "version": info.get("pkg-version"),
            "volume": volume,
            "location": location,
            "install_time": install_time,
            "installed_on": (time.strftime("%Y-%m-%d %H:%M", time.localtime(install_time))
                             if isinstance(install_time, (int, float)) else None),
            "files_total": len(relatives),
            "files_checked": len(checked),
            "files_present": present,
            "sampled": sampled,
            "state": state,
        })
    receipts.sort(key=lambda r: (r["install_time"] or 0), reverse=True)
    return receipts, {"source": "receipts", "status": "ok", "count": len(receipts),
                      "unreadable": unreadable}


def summarize_vendors(receipts: list[dict]) -> list[dict]:
    """Per-vendor rollup, non-Apple first: the shape a person actually reads."""
    groups: dict[str, dict] = {}
    for receipt in receipts:
        group = groups.setdefault(receipt["vendor"], {
            "vendor": receipt["vendor"], "apple": receipt["apple"], "packages": 0,
            "states": {}, "installed_on": None})
        group["packages"] += 1
        group["states"][receipt["state"]] = group["states"].get(receipt["state"], 0) + 1
        if receipt["installed_on"] and (group["installed_on"] is None
                                        or receipt["installed_on"] > group["installed_on"]):
            group["installed_on"] = receipt["installed_on"]
    for group in groups.values():
        states = group["states"]
        living = states.get("present", 0) + states.get("partial", 0)
        group["fully_removed"] = living == 0 and states.get("vanished", 0) > 0
    return sorted(groups.values(),
                  key=lambda g: (g["apple"], not g["fully_removed"], g["vendor"]))


# ---------------------------------------------------------------------------
# Trust-store roots
# ---------------------------------------------------------------------------

_CERT_LINE = re.compile(r"^\s*Cert\s+\d+:\s*(?P<name>.+?)\s*$")
_SETTINGS_COUNT = re.compile(r"^\s*Number of trust settings\s*:\s*(?P<count>\d+)\s*$")
_RESULT_TYPE = re.compile(r"^\s*Result Type\s*:\s*(?P<value>\S+)\s*$")
_POLICY_OID = re.compile(r"^\s*Policy OID\s*:\s*(?P<value>.+?)\s*$")


def parse_trust_settings(text: str, domain: str) -> list[dict]:
    """Parse one `security dump-trust-settings` dump into per-certificate rows."""
    roots: list[dict] = []
    current: Optional[dict] = None
    for line in text.splitlines():
        match = _CERT_LINE.match(line)
        if match:
            current = {"name": match.group("name"), "domain": domain,
                       "settings_count": None, "policies": [], "result_types": []}
            roots.append(current)
            continue
        if current is None:
            continue
        match = _SETTINGS_COUNT.match(line)
        if match:
            current["settings_count"] = int(match.group("count"))
            continue
        match = _RESULT_TYPE.match(line)
        if match:
            current["result_types"].append(match.group("value"))
            continue
        match = _POLICY_OID.match(line)
        if match:
            current["policies"].append(match.group("value"))
    for root in roots:
        # macOS trust-settings semantics: a certificate listed in a trust domain
        # with an EMPTY usage-constraints array means "trust as root, for every
        # policy". Zero settings is therefore the broadest possible grant, not
        # the narrowest -- the reading that looks like "nothing configured" is
        # exactly backwards, so it is named explicitly here.
        root["unconditional"] = root["settings_count"] == 0
        root["trusted_as_root"] = (root["unconditional"]
                                   or any("TrustAsRoot" in value
                                          for value in root["result_types"]))
    return roots


_DN_COMPONENT = re.compile(r"(?:^|[/,])\s*(?P<key>[A-Za-z]+)=(?P<value>[^/,]+)")


def parse_dn(text: str) -> dict:
    """Distinguished name -> dict. Tolerates both the slash-separated form
    LibreSSL prints and the comma-separated form OpenSSL 3 prints."""
    body = text.split("=", 1)[1] if text.lower().startswith(("subject=", "issuer=")) else text
    return {m.group("key").upper(): m.group("value").strip()
            for m in _DN_COMPONENT.finditer(body)}


def _parse_openssl_date(text: str) -> Optional[float]:
    value = text.split("=", 1)[-1].strip().replace(" GMT", "")
    for fmt in ("%b %d %H:%M:%S %Y", "%b  %d %H:%M:%S %Y"):
        try:
            return calendar.timegm(time.strptime(value, fmt))
        except ValueError:
            continue
    return None


def describe_certificate(pem: str, run: Runner, now_ts: float) -> Optional[dict]:
    code, out = run([OPENSSL, "x509", "-noout", "-subject", "-issuer",
                     "-startdate", "-enddate", "-serial"], pem)
    if code != 0 or not out.strip():
        return None
    fields: dict[str, str] = {}
    for line in out.splitlines():
        key, _, value = line.partition("=")
        fields[key.strip().lower()] = value.strip()
    subject = parse_dn("subject=" + fields.get("subject", ""))
    issuer = parse_dn("issuer=" + fields.get("issuer", ""))
    not_after = _parse_openssl_date(fields.get("notafter", ""))
    not_before = _parse_openssl_date(fields.get("notbefore", ""))

    code, text = run([OPENSSL, "x509", "-noout", "-text"], pem)
    is_ca = "CA:TRUE" in text if code == 0 else None
    key_bits = None
    key_match = re.search(r"Public-Key:\s*\((\d+) bit\)", text or "")
    if key_match:
        key_bits = int(key_match.group(1))
    return {
        "subject": subject,
        "issuer": issuer,
        "organization": subject.get("O") or subject.get("CN"),
        "self_signed": bool(subject) and subject == issuer,
        "is_ca": is_ca,
        "key_bits": key_bits,
        "serial": fields.get("serial"),
        "not_before": (time.strftime("%Y-%m-%d", time.gmtime(not_before))
                       if not_before else None),
        "not_after": (time.strftime("%Y-%m-%d", time.gmtime(not_after))
                      if not_after else None),
        "expired": bool(not_after and not_after < now_ts),
        "days_left": (round((not_after - now_ts) / 86400) if not_after else None),
    }


def _split_pems(text: str) -> list[str]:
    return [block + "-----END CERTIFICATE-----\n"
            for block in text.split("-----END CERTIFICATE-----")
            if "-----BEGIN CERTIFICATE-----" in block]


def collect_trust_roots(run: Runner = run_command, *,
                        now_ts: Optional[float] = None) -> tuple[list[dict], dict]:
    now = time.time() if now_ts is None else now_ts
    roots: list[dict] = []
    statuses: list[str] = []
    for domain, args in (("admin", [SECURITY, "dump-trust-settings", "-d"]),
                         ("user", [SECURITY, "dump-trust-settings"])):
        code, out = run(args, None)
        if code != 0 and not out.strip():
            statuses.append(f"{domain}:unavailable")
            continue
        statuses.append(f"{domain}:ok")
        roots.extend(parse_trust_settings(out, domain))
    for root in roots:
        code, pem_out = run([SECURITY, "find-certificate", "-a", "-c", root["name"], "-p"], None)
        pems = _split_pems(pem_out) if code == 0 else []
        root["matches"] = len(pems)
        root["certificate"] = describe_certificate(pems[0], run, now) if pems else None
    return roots, {"source": "trust_roots", "status": "|".join(statuses) or "unavailable",
                   "count": len(roots)}


# ---------------------------------------------------------------------------
# Correlation — the verdict neither source produces alone
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(r"[^a-z0-9]+")


def _vendor_token(value: Optional[str]) -> str:
    return _TOKEN_RE.sub("", (value or "").lower())


def attribute_roots(roots: list[dict], receipts: list[dict]) -> None:
    """Link each trusted root to the package family that installed it.

    Matching is on the vendor token shared between the certificate's
    organization and the package id -- both vendor-chosen strings, so a match is
    evidence rather than a heuristic guess. No match yields `unattributed`,
    which is a statement about attribution, not about the root's legitimacy.
    """
    by_vendor: dict[str, list[dict]] = {}
    for receipt in receipts:
        by_vendor.setdefault(receipt["vendor"], []).append(receipt)
    for root in roots:
        certificate = root.get("certificate") or {}
        token = _vendor_token(certificate.get("organization")) or _vendor_token(root["name"])
        owners = [pkgs for vendor, pkgs in sorted(by_vendor.items())
                  if token and token in _vendor_token(vendor)]
        packages = [pkg for group in owners for pkg in group]
        root["owner_packages"] = [pkg["pkgid"] for pkg in packages]
        if not packages:
            root["attribution"] = "unattributed"
            root["verdict"] = "unattributed"
        else:
            root["attribution"] = "attributed"
            living = [pkg for pkg in packages if pkg["state"] in ("present", "partial")]
            root["owner_installed_on"] = max(
                (pkg["installed_on"] for pkg in packages if pkg["installed_on"]), default=None)
            root["verdict"] = "attributed" if living else "orphaned"
        root["evidence"] = "preview"


def _root_rank(root: dict) -> tuple:
    certificate = root.get("certificate") or {}
    return (
        0 if root["verdict"] == "orphaned" else 1 if root["verdict"] == "unattributed" else 2,
        0 if root.get("unconditional") else 1,
        0 if certificate.get("is_ca") else 1,
        -(certificate.get("days_left") or 0),
        root["name"],
    )


def build_moraine(run: Runner = run_command, *, now_ts: Optional[float] = None,
                  sample_cap: int = FILE_SAMPLE_CAP) -> dict:
    now = time.time() if now_ts is None else now_ts
    receipts, receipt_status = collect_receipts(run, sample_cap=sample_cap)
    roots, root_status = collect_trust_roots(run, now_ts=now)
    attribute_roots(roots, receipts)
    roots.sort(key=_root_rank)
    vendors = summarize_vendors(receipts)
    non_apple = [v for v in vendors if not v["apple"]]
    return {
        "contract": ("read-only; installer receipts and trust-store entries only; "
                     "no file content read, nothing written, nothing deleted"),
        "evidence": "preview",
        "prior_art": ("AppCleaner covers the file-sweep half of this and covers it well; "
                      "it is target-driven and cannot open the trust store, which is the "
                      "half reported here"),
        "sources": [receipt_status, root_status],
        "receipts": {
            "total": len(receipts),
            "non_apple": sum(1 for r in receipts if not r["apple"]),
            "vanished": sum(1 for r in receipts if r["state"] == "vanished"),
            "sampled": sum(1 for r in receipts if r["sampled"]),
            "vendors": vendors,
        },
        "trust_roots": {
            "total": len(roots),
            "orphaned": sum(1 for r in roots if r["verdict"] == "orphaned"),
            "unattributed": sum(1 for r in roots if r["verdict"] == "unattributed"),
            "unconditional": sum(1 for r in roots if r.get("unconditional")),
            "items": roots,
        },
        "removed_vendors": [v["vendor"] for v in non_apple if v["fully_removed"]],
    }


# ---------------------------------------------------------------------------
# Text report
# ---------------------------------------------------------------------------

_VERDICT_LABEL = {
    "orphaned": "orphaned — installing package has no payload left",
    "unattributed": "unattributed — no installer receipt claims it",
    "attributed": "attributed — owner package still installed",
}


def render_report(report: dict, limit: int) -> str:
    lines = ["Modore moraine — what stayed after the installer left "
             "(read-only · receipts + trust store · preview evidence)"]
    lines.append("sources: " + " · ".join(
        f"{s['source']} {s['status']} ({s['count']})" for s in report["sources"]))
    receipts = report["receipts"]
    lines.append(f"receipts {receipts['total']} — non-Apple {receipts['non_apple']}"
                 f" · payload gone {receipts['vanished']}"
                 + (f" · file-sampled {receipts['sampled']}" if receipts["sampled"] else ""))
    roots = report["trust_roots"]
    lines.append(f"trusted roots {roots['total']} — orphaned {roots['orphaned']}"
                 f" · unattributed {roots['unattributed']}"
                 f" · unconditional {roots['unconditional']}")

    if roots["items"]:
        lines.append("")
        lines.append("trusted roots (worst first)")
    for root in roots["items"][:limit]:
        certificate = root.get("certificate") or {}
        marks = [_VERDICT_LABEL.get(root["verdict"], root["verdict"])]
        if root.get("unconditional"):
            marks.append("all policies")
        if certificate.get("expired"):
            marks.append("EXPIRED")
        lines.append(f"  {root['name']} [{root['domain']}] — " + " · ".join(marks))
        if certificate:
            shape = []
            if certificate.get("self_signed"):
                shape.append("self-signed")
            if certificate.get("is_ca"):
                shape.append("CA:TRUE")
            if certificate.get("key_bits"):
                shape.append(f"{certificate['key_bits']}-bit")
            window = f"{certificate.get('not_before') or '?'} → {certificate.get('not_after') or '?'}"
            days = certificate.get("days_left")
            lines.append(f"     {' · '.join(shape) or 'certificate'} | {window}"
                         + (f" ({days}d left)" if days is not None and days > 0 else ""))
        if root.get("owner_packages"):
            shown = ", ".join(root["owner_packages"][:3])
            more = len(root["owner_packages"]) - 3
            lines.append(f"     installed by: {shown}" + (f" (+{more})" if more > 0 else "")
                         + (f", {root['owner_installed_on']}" if root.get("owner_installed_on") else ""))
    if len(roots["items"]) > limit:
        lines.append(f"  … {len(roots['items']) - limit} more (--limit or --json)")

    removed = report["removed_vendors"]
    if removed:
        lines.append("")
        lines.append(f"vendors whose packages are all gone from disk ({len(removed)}): "
                     + ", ".join(removed[:12]) + ("…" if len(removed) > 12 else ""))
    lines.append("")
    lines.append("Nothing here is deleted or scheduled for deletion. Removing a trust root is "
                 "an admin act and stays a human decision.")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit what stayed behind after software was removed.")
    parser.add_argument("--json", action="store_true", help="print the full report as JSON")
    parser.add_argument("--limit", type=int, default=10,
                        help="trusted roots to show in the text report")
    parser.add_argument("--sample-cap", type=int, default=FILE_SAMPLE_CAP,
                        help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.limit <= 0 or args.sample_cap <= 0:
        print("moraine: --limit and --sample-cap must be positive", file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("moraine: macOS only (reads pkgutil receipts and the macOS trust store)",
              file=sys.stderr)
        return 2
    report = build_moraine(sample_cap=args.sample_cap)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_report(report, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
