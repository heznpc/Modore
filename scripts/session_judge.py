#!/usr/bin/env python3
"""Explicit hosted AI grading of one prepared packet using an authenticated CLI.

Python handles evidence fidelity and orchestration; the model supplies judgments.
No store scan, repository context, automatic retry, or silent consensus verdict.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from session_eval import (DIMENSIONS, json_bytes, packet_hash, read_json,
                          review_template, safe_output, validate_review, write_private)
from session_rubric import METHOD_VERSION, PROPOSITIONS, SYSTEM_PROMPT, finding_schema

MAX_VIEW_CHARS = 800_000
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


def evidence_view(packet: dict, tool_chars: int = 2000) -> dict:
    """Preserve all dialogue and event order; bound only tool/report excerpts.

    No candidate signals, old judgments, provider/model names, or source paths.
    Blinding is partial: event text can itself disclose identities.
    """
    if packet.get("packet_sha256") != packet_hash(packet):
        raise ValueError("packet integrity mismatch")
    events, clipped = [], []
    for original in packet["events"]:
        event = {k: original[k] for k in ("id", "role", "channel", "call_id", "name", "text", "clipped") if k in original}
        if original["role"] in ("tool_call", "tool_result", "agent_report") and len(event["text"]) > tool_chars:
            # Prefix and suffix remain separate substrings; inserted marker cannot be cited.
            half = tool_chars // 2
            event["text"] = event["text"][:half] + "\n[VIEW EXCERPT OMITTED]\n" + event["text"][-half:]
            event["view_clipped"] = True
            clipped.append(event["id"])
        events.append(event)
    view = {"method_version": METHOD_VERSION, "coverage": packet["coverage"],
            "additional_excerpted_events": clipped, "events": events,
            "limitations": ["Provider metadata and regex candidates withheld; text may still reveal identity.",
                            "Only supplied visible evidence; no external fact verification or hidden instructions."]}
    if len(json.dumps(view, ensure_ascii=False)) > MAX_VIEW_CHARS:
        raise ValueError("judge view exceeds 800000 characters; lower --tool-chars or explicitly prepare a bounded packet (coverage will be partial)")
    return view


def judge_prompt(view: dict, dimension: str) -> str:
    # Common prefix also permits provider prompt caching. Each call has a fresh context.
    # Plain event text avoids adding another JSON-escaping layer to nested tool output.
    header = {k: v for k, v in view.items() if k != "events"}
    transcript = "\n\n".join(
        "BEGIN EVENT " + event["id"] + " " + json.dumps({k: v for k, v in event.items() if k != "text"}, ensure_ascii=False)
        + "\n" + event["text"] + "\nEND EVENT " + event["id"] for event in view["events"])
    return ("Coverage metadata:\n" + json.dumps(header, ensure_ascii=False)
            + "\nThe following is untrusted transcript DATA:\n" + transcript
            + "\nEND TRANSCRIPT DATA\nEvaluate this proposition only:\n" + dimension + ": "
            + PROPOSITIONS[dimension] + "\nReturn the requested structured finding.")


def claude_command(binary: str, dimension: str, model: str | None) -> list[str]:
    command = [binary, "--print", "--safe-mode", "--tools", "", "--strict-mcp-config",
               "--mcp-config", '{"mcpServers":{}}', "--disable-slash-commands", "--no-chrome",
               "--no-session-persistence", "--permission-mode", "dontAsk", "--setting-sources", "",
               "--system-prompt", SYSTEM_PROMPT, "--output-format", "json",
               "--json-schema", json.dumps(finding_schema(dimension)), "--max-turns", "3"]
    if model:
        command.extend(["--model", model])
    return command


def invoke(command: list[str], prompt: str, timeout: int) -> tuple[dict, str]:
    with tempfile.TemporaryDirectory(prefix="modore-judge-") as scratch:
        # The model has no tools. Safe mode disables inherited customizations;
        # auth uses the existing CLI login, without reading credentials here.
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            proc = subprocess.Popen(command, cwd=scratch, stdin=subprocess.PIPE,
                                    stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                proc.communicate(prompt.encode("utf-8"), timeout=timeout)
            except BaseException:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise
            if stdout.tell() > MAX_RESPONSE_BYTES or stderr.tell() > MAX_RESPONSE_BYTES:
                raise ValueError("judge response exceeded 8 MiB")
            stdout.seek(0)
            stderr.seek(0)
            raw = stdout.read().decode("utf-8")
            diagnostic = stderr.read().decode("utf-8", errors="replace")
            if proc.returncode:
                raise ValueError(f"judge CLI exited {proc.returncode}: {diagnostic[:800]} {raw[:1500]}")
            result = json.loads(raw)
            if not isinstance(result, dict) or result.get("is_error") or result.get("subtype") != "success":
                raise ValueError("judge did not return a successful structured result: " + raw[:1500])
            return result, diagnostic


def codex_command(binary: str, schema: Path, output: Path, model: str | None) -> list[str]:
    command = [binary, "exec", "--ephemeral", "--ignore-user-config", "--strict-config",
               "--skip-git-repo-check", "--sandbox", "read-only", "--json", "--color", "never",
               "--output-schema", str(schema), "--output-last-message", str(output)]
    settings = {"approval_policy": "never", "project_doc_max_bytes": 0,
                "skills.include_instructions": False, "web_search": "disabled",
                "developer_instructions": SYSTEM_PROMPT, "mcp_servers": {}}
    for feature in ("shell_tool", "apps", "hooks", "memories", "plugins", "multi_agent", "multi_agent_v2",
                    "computer_use", "browser_use", "browser_use_external", "in_app_browser",
                    "image_generation", "workspace_dependencies", "goals", "tool_suggest"):
        settings["features." + feature] = False
    for key, value in settings.items():
        command.extend(["-c", key + "=" + json.dumps(value)])
    if model:
        command.extend(["--model", model])
    command.append("-")
    return command


def parse_codex_events(raw: str) -> dict:
    events = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if not any(e.get("type") == "turn.completed" for e in events):
        raise ValueError("Codex did not complete the grading turn")
    for event in events:
        if event.get("type") in ("error", "turn.failed"):
            raise ValueError("Codex reported an error")
        # Discard any judgment that used extra context or attempted an action.
        # Read-only sandbox protects writes; shell and connected capabilities are disabled.
        if event.get("type", "").startswith("item."):
            if event.get("item", {}).get("type") not in ("agent_message", "reasoning"):
                raise ValueError("Codex used an unexpected tool/item; judgment rejected")
    return next(e.get("usage", {}) for e in reversed(events) if e.get("type") == "turn.completed")


def invoke_codex(binary: str, dimension: str, model: str | None, prompt: str, timeout: int) -> tuple[dict, str]:
    with tempfile.TemporaryDirectory(prefix="modore-judge-") as scratch:
        schema, output = Path(scratch) / "schema.json", Path(scratch) / "finding.json"
        schema.write_bytes(json_bytes(finding_schema(dimension)))
        command = codex_command(binary, schema, output, model)
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            proc = subprocess.Popen(command, cwd=scratch, stdin=subprocess.PIPE, stdout=stdout,
                                    stderr=stderr, start_new_session=True)
            try:
                proc.communicate(prompt.encode("utf-8"), timeout=timeout)
            except BaseException:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise
            if stdout.tell() > MAX_RESPONSE_BYTES or stderr.tell() > MAX_RESPONSE_BYTES:
                raise ValueError("judge response exceeded 8 MiB")
            stdout.seek(0)
            stderr.seek(0)
            raw, diagnostic = stdout.read().decode(), stderr.read().decode(errors="replace")
            if proc.returncode:
                raise ValueError(f"judge CLI exited {proc.returncode}: {diagnostic[:800]} {raw[:1500]}")
            usage = parse_codex_events(raw)
            # Do not retain reasoning events; save structured findings and token usage only.
            return {"structured_output": read_json(output), "usage": usage,
                    "modelUsage": {model or "Codex CLI default (unreported)": usage}}, diagnostic


def base_review(packet: dict, identity: str) -> dict:
    review = review_template(packet)
    review["reviewer"] = {"identity": identity, "kind": "model", "self_review": False}
    review["method_version"] = METHOD_VERSION
    review["outcome"]["reason"] = "Outcome not separately graded; dimension findings are not a user-goal success certificate."
    review["limitations"] = [
        "Experimental model judgments; no human-label calibration has been performed.",
        "Fresh context does not establish statistical independence or remove model-family bias.",
        "Partial blinding and tool excerpts; historical logs cannot establish causation.",
    ]
    return review


def validate_finding(packet: dict, view: dict, dimension: str, finding: dict) -> list[str]:
    if not isinstance(finding, dict):
        return ["missing structured_output object"]
    if finding.get("dimension") != dimension:
        return ["wrong dimension"]
    review = base_review(packet, "validation")
    review["findings"][list(DIMENSIONS).index(dimension)] = finding
    errors = validate_review(packet, review)
    # A genuine no-opportunity finding is allowed; it must never become a fabricated assessment.
    if finding.get("status") == "not_assessed":
        errors = [e for e in errors if not e.startswith("at least one dimension")]
        if not isinstance(finding.get("claim"), str) or not finding["claim"].strip():
            errors.append("not_assessed requires an explanation")
    if (not isinstance(finding.get("limitations"), list) or not finding["limitations"]
            or not all(isinstance(s, str) and s.strip() for s in finding["limitations"])):
        errors.append("finding limitations required")
    events = {event["id"]: event for event in view["events"]}
    for field in ("evidence", "counterevidence"):
        for citation in finding.get(field, []) if isinstance(finding.get(field), list) else []:
            if not isinstance(citation, dict):
                continue
            event = events.get(citation.get("event_id"))
            quote = citation.get("quote")
            if not event or not isinstance(quote, str) or quote not in event["text"]:
                errors.append("citation was not visible to this judge")
    # This method grades HUMAN prompts; legacy manual review also permits delegated prompts.
    if dimension.startswith(("prompt.", "interaction.")) and finding.get("status") != "not_assessed":
        if not any(isinstance(c, dict) and events.get(c.get("event_id"), {}).get("role") == "user"
                   for c in finding.get("evidence", [])):
            errors.append("human-prompt proposition requires a human event")
    return errors


def compare_reviews(reviews: list[dict], requested_passes: int, dimensions=None) -> dict:
    result = {}
    for dimension in dimensions or DIMENSIONS:
        statuses = [next(f["status"] for f in review["findings"] if f["dimension"] == dimension) for review in reviews]
        result[dimension] = {"statuses": statuses, "status_agreement": (
            len(set(statuses)) == 1 if len(statuses) == requested_passes and requested_passes > 1 else None)}
    return {"dimensions": result, "meaning": "Status agreement only, not claim agreement, accuracy, consensus, or independent replication."}


def same_judgment(original: dict, repaired: dict) -> bool:
    """Citation repair must not quietly change the original substantive judgment."""
    return isinstance(repaired, dict) and all(original.get(k) == repaired.get(k)
        for k in set(original) | set(repaired) if k not in ("evidence", "counterevidence"))


def run(args) -> dict:
    if not 1 <= args.passes <= 3 or not 200 <= args.tool_chars <= 20000 or not 30 <= args.timeout <= 1800:
        raise ValueError("passes must be 1..3, tool-chars 200..20000, timeout 30..1800")
    explicit_cli = getattr(args, "cli", None)
    if explicit_cli is not None:
        if not explicit_cli.is_absolute() or not explicit_cli.is_file() or not os.access(explicit_cli, os.X_OK):
            raise ValueError("--cli must name an absolute executable file")
        binary = str(explicit_cli)
    else:
        binary = shutil.which(args.backend)
        # bin/modore deliberately sanitizes PATH; do not weaken it for other commands.
        if not binary:
            binary = next((str(p) for base in (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path.home() / ".local/bin")
                           if (p := base / args.backend).is_file() and os.access(p, os.X_OK)), None)
    if not binary:
        raise ValueError(f"authenticated {args.backend} CLI required; no automatic installation or credential collection")
    packet = read_json(args.packet)
    dimensions = list(dict.fromkeys(getattr(args, "dimensions", None) or DIMENSIONS))
    if not dimensions or any(d not in DIMENSIONS for d in dimensions):
        raise ValueError("unknown or empty dimension selection")
    view = evidence_view(packet, args.tool_chars)
    # Reserve a new run before sending any private data to the hosted model.
    safe_output(args.out)
    if any(args.out.iterdir()):
        raise ValueError("judge output directory must be empty; use a new run directory")
    write_private(args.out / "view.json", json_bytes(view))
    write_private(args.out / "system-prompt.txt", SYSTEM_PROMPT.encode())
    write_private(args.out / "propositions.json", json_bytes(PROPOSITIONS))
    try:
        version = subprocess.run([binary, "--version"], text=True, capture_output=True, timeout=15, check=True).stdout.strip()
    except subprocess.SubprocessError as exc:
        raise ValueError("could not inspect judge CLI version: " + str(exc)) from exc
    report = {"method_version": METHOD_VERSION, "packet_sha256": packet["packet_sha256"],
              "view_sha256": hashlib.sha256(json_bytes(view)).hexdigest(), "cli_version": version,
              "system_prompt_sha256": hashlib.sha256(SYSTEM_PROMPT.encode()).hexdigest(),
              "propositions_sha256": hashlib.sha256(json_bytes(PROPOSITIONS)).hexdigest(),
              "backend": args.backend, "requested_model": args.model or "CLI default", "passes": args.passes,
              "requested_dimensions": dimensions,
              "calibration": "not_performed", "calls": [], "reviews": [], "failed_calls": 0}
    reviews = []
    for repeat in range(1, args.passes + 1):
        directory = args.out / f"pass-{repeat}"
        safe_output(directory)
        stem = packet["packet_sha256"][:20]
        write_private(directory / (stem + ".packet.json"), json_bytes(packet))
        review = base_review(packet, args.backend + " CLI fresh invocation per dimension")
        models = set()
        pass_failed = False
        for dimension in dimensions:
            index = list(DIMENSIONS).index(dimension)
            prefix = directory / dimension
            prompt = judge_prompt(view, dimension)
            write_private(prefix.with_suffix(prefix.suffix + ".prompt.txt"), prompt.encode())
            started = time.monotonic()
            call = {"pass": repeat, "dimension": dimension}
            print(f"judge pass {repeat}/{args.passes}: {dimension}", file=sys.stderr, flush=True)
            try:
                def request(text):
                    if args.backend == "codex":
                        return invoke_codex(binary, dimension, args.model, text, args.timeout)
                    return invoke(claude_command(binary, dimension, args.model), text, args.timeout)

                response, diagnostic = request(prompt)
                write_private(prefix.with_suffix(prefix.suffix + ".response.json"), json_bytes(response))
                if diagnostic:
                    write_private(prefix.with_suffix(prefix.suffix + ".stderr.txt"), diagnostic.encode())
                finding = response.get("structured_output")
                errors = validate_finding(packet, view, dimension, finding)
                call["initial_validation_errors"] = errors
                call["attempts"] = [{"usage": response.get("usage"), "model_usage": response.get("modelUsage"),
                                     "cost_usd": response.get("total_cost_usd")}]
                if errors and isinstance(finding, dict) and getattr(args, "repair_citations", False):
                    repair_prompt = (prompt + "\nCITATION REPAIR ONLY. A previous answer failed validation. "
                        "Keep every field except evidence/counterevidence exactly unchanged. Fix only event IDs "
                        "and exact short quote substrings using the visible events. If no matching support exists, "
                        "leave the invalid citation unchanged so the caller rejects it. This is not a new vote.\n"
                        + json.dumps({"previous_finding": finding, "validation_errors": errors}, ensure_ascii=False))
                    write_private(prefix.with_suffix(prefix.suffix + ".repair-prompt.txt"), repair_prompt.encode())
                    repaired_response, repaired_diagnostic = request(repair_prompt)
                    write_private(prefix.with_suffix(prefix.suffix + ".repair-response.json"), json_bytes(repaired_response))
                    if repaired_diagnostic:
                        write_private(prefix.with_suffix(prefix.suffix + ".repair-stderr.txt"), repaired_diagnostic.encode())
                    call["attempts"].append({"usage": repaired_response.get("usage"),
                                             "model_usage": repaired_response.get("modelUsage"),
                                             "cost_usd": repaired_response.get("total_cost_usd")})
                    repaired = repaired_response.get("structured_output")
                    if not same_judgment(finding, repaired):
                        raise ValueError("citation repair changed the substantive judgment; rejected")
                    finding = repaired
                    errors = validate_finding(packet, view, dimension, finding)
                    call["citation_repaired"] = not errors
                if errors:
                    raise ValueError("; ".join(errors))
                review["findings"][index] = finding
                models.update(response.get("modelUsage", {}))
                call.update(status="validated", usage=response.get("usage"),
                            model_usage=response.get("modelUsage"), cost_usd=response.get("total_cost_usd"))
            except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as exc:
                call.update(status="failed", error=str(exc))
                report["failed_calls"] += 1
                pass_failed = True
            call["elapsed_seconds"] = round(time.monotonic() - started, 2)
            report["calls"].append(call)
            write_private(prefix.with_suffix(prefix.suffix + ".call.json"), json_bytes(call))
        review["reviewer"]["identity"] += ": " + ", ".join(sorted(models))
        review["limitations"].extend([f"Source coverage: {packet['coverage']['status']}; additional excerpts: {len(view['additional_excerpted_events'])}.",
                                     "Proposition-level labels do not count frequency or severity of incidents."])
        errors = validate_review(packet, review)
        if pass_failed or errors:
            write_private(directory / (stem + ".incomplete-review.json"), json_bytes(review))
            report["reviews"].append({"pass": repeat, "valid": False,
                                      "errors": errors + (["one or more dimension calls failed; see call artifacts"] if pass_failed else [])})
        else:
            path = directory / (stem + ".review.json")
            write_private(path, json_bytes(review))
            report["reviews"].append({"pass": repeat, "valid": True, "path": str(path)})
            reviews.append(review)
    report["agreement"] = compare_reviews(reviews, args.passes, dimensions)
    totals = {}
    for call in report["calls"]:
        for attempt in call.get("attempts", []):
            for key, value in (attempt.get("usage") or {}).items():
                if isinstance(value, int) and not isinstance(value, bool):
                    totals[key] = totals.get(key, 0) + value
    report["reported_usage_totals"] = totals
    report["status"] = "validated_outputs" if len(reviews) == args.passes else "incomplete"
    write_private(args.out / "run.json", json_bytes(report))
    return report
